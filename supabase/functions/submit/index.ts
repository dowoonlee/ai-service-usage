// POST /submit
// 클라이언트가 폴링 주기 직후 호출. HMAC 서명 검증 + 시간 비례 캡 + append.
//
// 어뷰징 캡 정책 (caps.ts):
//   - 시간 비례 cap = elapsed * 0.05 coins/sec (floor 1000, ceiling 50000)
//   - delta > cap이면 cap으로 truncate, `cap_applied = true` 기록. silently truncate
//     (사용자에겐 accepted=true로 응답하되 totalCoins는 cap 적용된 값)
//   - prev_total 10% drift 초과 시 reject (`prev_total_mismatch`)
//   - 음수 delta, replay, 미등록 device 모두 reject
//
// 트랜잭션: users.total_coins 갱신 + submissions insert가 한 atomic 작업이어야 race-free.
// PostgREST는 단일 트랜잭션 명령이 없으므로 RPC 함수로 묶거나 두 호출 후 일관성 점검.
// 50명 규모 + 같은 device가 같은 시점에 2회 호출할 가능성 0이라 두 호출 + dedupe 정도면 충분.

import { jsonResponse, errorResponse, handleOptions } from "../_shared/cors.ts";
import { getDb } from "../_shared/db.ts";
import { verifyHmac } from "../_shared/hmac.ts";
import { isValidUUID } from "../_shared/validation.ts";
import { evaluateCap } from "../_shared/caps.ts";

interface SubmitPayload {
  deviceId: string;
  delta: number;
  prevTotal: number;
  ts: number;
}
interface SubmitRequest {
  payload: SubmitPayload;
  signature: string;
  // 보드 표시용 opaque blob. payload 외부에 두어 HMAC 서명 대상 아님 (display data).
  // 수신 시 항상 최신값으로 update — 변조 위험은 "잘못된 카드 노출" 정도라 50명 + 수동
  // 큐레이션 환경에서 수용 가능.
  profileJson?: unknown;
}

// ts 허용 윈도우. 클라이언트 시계가 60분 이상 어긋난 경우만 reject.
const MAX_CLOCK_SKEW_SEC = 3600;

Deno.serve(async (req: Request) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;
  if (req.method !== "POST") return errorResponse(405, "method_not_allowed");

  let body: SubmitRequest;
  try {
    body = await req.json();
  } catch {
    return errorResponse(400, "invalid_json");
  }
  const p = body.payload;
  if (!p || typeof p !== "object") return errorResponse(400, "missing_payload");
  if (!isValidUUID(p.deviceId)) return errorResponse(400, "invalid_device_id");
  if (typeof body.signature !== "string" || body.signature.length !== 64) {
    return errorResponse(400, "invalid_signature");
  }
  if (typeof p.delta !== "number" || typeof p.prevTotal !== "number" || typeof p.ts !== "number") {
    return errorResponse(400, "invalid_payload_types");
  }

  // 클라이언트 시계 skew 검사 (replay 1차 방어)
  const nowSec = Math.floor(Date.now() / 1000);
  if (Math.abs(nowSec - p.ts) > MAX_CLOCK_SKEW_SEC) {
    return errorResponse(400, "clock_skew");
  }

  const db = getDb();
  const { data: user, error: userErr } = await db
    .from("users")
    .select("device_id, hmac_key_b64, total_coins, status, last_submitted_at")
    .eq("device_id", p.deviceId)
    .single();
  if (userErr || !user) return errorResponse(404, "device_not_registered");
  if (user.status === "banned") return errorResponse(403, "banned");

  const ok = await verifyHmac(
    { delta: p.delta, deviceId: p.deviceId, prevTotal: p.prevTotal, ts: p.ts },
    body.signature,
    user.hmac_key_b64,
  );
  if (!ok) return errorResponse(401, "bad_signature");

  // elapsed: 서버측 last_submitted_at 기준. 클라이언트 신뢰 안 함.
  // 첫 제출(last_submitted_at = null)이면 0 → floor cap 적용.
  const lastAt = user.last_submitted_at ? new Date(user.last_submitted_at).getTime() : 0;
  const elapsedSec = lastAt > 0 ? Math.max(0, (Date.now() - lastAt) / 1000) : 0;

  const decision = evaluateCap({
    delta: p.delta,
    elapsedSeconds: elapsedSec,
    prevTotalReported: p.prevTotal,
    prevTotalServer: user.total_coins,
  });

  let accepted = 0;
  let capApplied = false;
  let rejectReason: string | null = null;
  let acceptedFlag = false;

  if (decision.kind === "rejected") {
    rejectReason = decision.reason;
  } else if (decision.kind === "truncated") {
    accepted = decision.accepted;
    capApplied = true;
    acceptedFlag = true;
  } else {
    accepted = decision.accepted;
    acceptedFlag = true;
  }

  // submissions append (audit log) — accepted=false도 기록.
  // shadow_banned 사용자: accept처럼 처리하되 total_coins는 갱신 안 함.
  const writeTotal = user.status === "shadow_banned" ? user.total_coins : user.total_coins + accepted;

  const { error: insertErr } = await db.from("submissions").insert({
    device_id: p.deviceId,
    delta_coins: p.delta,
    accepted_coins: accepted,
    elapsed_seconds: Math.floor(elapsedSec),
    client_ts: p.ts,
    accepted: acceptedFlag,
    cap_applied: capApplied,
    reject_reason: rejectReason,
  });
  if (insertErr) {
    console.error("submission insert failed", insertErr);
    return errorResponse(500, "insert_failed");
  }

  // profile_json은 매 submit마다 최신화 (변경 있을 수 있어 매번 update).
  // 50명 규모라 매 호출 update 비용 무시. 변경 감지 로직 추가는 over-engineering.
  const updates: Record<string, unknown> = {};
  if (acceptedFlag && accepted > 0 && user.status !== "shadow_banned") {
    updates.total_coins = writeTotal;
  }
  if (acceptedFlag) {
    updates.last_submitted_at = new Date().toISOString();
  }
  if (body.profileJson !== undefined) {
    updates.profile_json = body.profileJson;
  }
  if (Object.keys(updates).length > 0) {
    await db.from("users").update(updates).eq("device_id", p.deviceId);
  }

  // 캡 적용이 누적되면 abuse_flags에 기록 — 운영자가 수동 검토. 단발성 truncate는 무시.
  if (capApplied) {
    // 최근 24h에 cap_applied=true가 3회 이상이면 flag.
    const since = new Date(Date.now() - 24 * 3600 * 1000).toISOString();
    const { count } = await db
      .from("submissions")
      .select("id", { count: "exact", head: true })
      .eq("device_id", p.deviceId)
      .eq("cap_applied", true)
      .gte("submitted_at", since);
    if ((count ?? 0) >= 3) {
      await db.from("abuse_flags").insert({
        device_id: p.deviceId,
        reason: "frequent_cap_truncation",
        details: { recent_24h_truncations: count, last_delta: p.delta, cap_at: accepted },
      });
    }
  }

  return jsonResponse({
    accepted: acceptedFlag,
    totalCoins: writeTotal,
    rejectReason,
  });
});
