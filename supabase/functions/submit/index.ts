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
  // 클라이언트 버전 텔레메트리. profileJson과 동일하게 서명 대상 밖 display/운영용.
  // 변조 위험은 "버전 통계 오염" 정도라 수용. 길이만 sanity cap.
  appVersion?: string;
  osVersion?: string;
}

// 버전 문자열 sanity — 문자열 + 1..64자만 통과, 아니면 undefined (해당 컬럼 미갱신).
function sanitizeVersion(v: unknown): string | undefined {
  return typeof v === "string" && v.length > 0 && v.length <= 64 ? v : undefined;
}

// 프로필 위조 sanity. profileJson은 opaque 표시용이고 내용 진실성은 서버가 검증 불가다
// (클라 자가신고 + 사용량 서버 재계산 불가). 순위/보상은 total_coins(HMAC submit으로만 증가)
// 로만 산정하므로 프로필 위조의 피해는 "보드에 가짜 카드 노출"로 제한된다. 다만 배열 길이가
// 절대 상한을 넘는 명백한 오염/blob 폭주는 abuse_flags로 기록한다(저장은 막지 않음 — 표시
// 데이터라 차단 무의미). 상한은 실제 최대치(컬렉션 11, 뱃지 카테고리×티어)보다 넉넉히 둬
// false positive를 0으로 만든다.
const PROFILE_MAX_COLLECTIONS = 30;
const PROFILE_MAX_BADGES = 80;

function profileArrayOverflow(profile: unknown): { field: string; len: number } | null {
  if (!profile || typeof profile !== "object") return null;
  const p = profile as Record<string, unknown>;
  const cols = Array.isArray(p.completedCollections) ? p.completedCollections.length : 0;
  if (cols > PROFILE_MAX_COLLECTIONS) return { field: "completedCollections", len: cols };
  const badges = Array.isArray(p.clearedBadges) ? p.clearedBadges.length : 0;
  if (badges > PROFILE_MAX_BADGES) return { field: "clearedBadges", len: badges };
  return null;
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
    // 명백한 배열 오염만 flag — 내용 진실성(범위 내 거짓)은 검증 불가, 보상 미연동으로 피해 제한.
    const overflow = profileArrayOverflow(body.profileJson);
    if (overflow) {
      await db.from("abuse_flags").insert({
        device_id: p.deviceId,
        reason: "profile_array_overflow",
        details: { field: overflow.field, length: overflow.len },
      });
    }
    // 클라이언트가 로컬 plist 외부 조작을 자가 탐지(integrityViolation)했으면 flag. casual
    // deterrent — 클라 패치로 끌 수 있으나 defaults write만 한 조작자는 그대로 보고된다.
    // 매 submit마다 true가 오므로 24h 1회로 dedup(abuse_flags 폭주 방지).
    const prof = body.profileJson as Record<string, unknown> | null;
    if (prof && typeof prof === "object" && prof.integrityViolation === true) {
      const since = new Date(Date.now() - 24 * 3600 * 1000).toISOString();
      const { count } = await db
        .from("abuse_flags")
        .select("id", { count: "exact", head: true })
        .eq("device_id", p.deviceId)
        .eq("reason", "local_integrity_violation")
        .gte("flagged_at", since);
      if ((count ?? 0) === 0) {
        await db.from("abuse_flags").insert({
          device_id: p.deviceId,
          reason: "local_integrity_violation",
          details: { source: "client_self_report" },
        });
      }
    }
  }
  // 버전 텔레메트리 — accept/reject 무관하게 들어온 값이 유효하면 갱신 (현재 버전 추적이 목적).
  const appVersion = sanitizeVersion(body.appVersion);
  const osVersion = sanitizeVersion(body.osVersion);
  if (appVersion !== undefined) updates.app_version = appVersion;
  if (osVersion !== undefined) updates.os_version = osVersion;
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
