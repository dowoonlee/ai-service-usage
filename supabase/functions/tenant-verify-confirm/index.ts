// POST /tenant-verify-confirm — OTP 검증 후 게이트 테넌트로 편입(one-way). docs/plans/tenant.md §3-4.
//
// payload(서명 대상, flat): { deviceId, code, ts }
//   코드 소유 = 메일함 접근 증명이라 confirm에 이메일 재확인은 불필요(§3-4). 성공 시 apply_tenant_switch
//   RPC로 tenant_id 갱신 + 타 테넌트 길드 자동탈퇴를 원자 처리.
//   [보안] request와 동일하게 HMAC 서명 필수.

import { jsonResponse, errorResponse, handleOptions } from "../_shared/cors.ts";
import { getDb } from "../_shared/db.ts";
import { verifyHmac } from "../_shared/hmac.ts";
import { isValidUUID } from "../_shared/validation.ts";
import { sha256Hex } from "../_shared/tenant.ts";

interface ConfirmPayload {
  deviceId: string;
  code: string;
  ts: number;
}
interface ConfirmRequest {
  payload: ConfirmPayload;
  signature: string;
}

const MAX_CLOCK_SKEW_SEC = 3600;
const MAX_ATTEMPTS = 5;

// 사내 인증 유도 캠페인(v0.16.2) 보상 — 신규 인증자에게 RP 1회 지급. coin(3000)은 클라가 로컬
// 원장에 직접 지급하고, RP는 여기서 rp_rewards 미수령 행을 넣어 다음 폴링 때 클라가 자동 수령한다.
// sentinel period '2099-00'은 실존 월이 아니고 기존 정산(2026-*)·버그보상(2026-00)과 무충돌.
// UNIQUE(period_type, period, device_id) + upsert ignoreDuplicates 로 재호출에도 멱등.
const TENANT_VERIFY_RP_PERIOD = "2099-00";
const TENANT_VERIFY_RP_AMOUNT = 3000;

Deno.serve(async (req: Request) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;
  if (req.method !== "POST") return errorResponse(405, "method_not_allowed");

  let body: ConfirmRequest;
  try {
    body = await req.json();
  } catch {
    return errorResponse(400, "invalid_json");
  }
  const p = body.payload;
  if (!p || typeof p !== "object") return errorResponse(400, "missing_payload");
  if (!isValidUUID(p.deviceId)) return errorResponse(400, "invalid_device_id");
  if (typeof p.code !== "string" || !/^\d{6}$/.test(p.code)) return errorResponse(400, "invalid_code");
  if (typeof body.signature !== "string" || body.signature.length !== 64) {
    return errorResponse(400, "invalid_signature");
  }
  if (typeof p.ts !== "number") return errorResponse(400, "invalid_ts");
  const nowSec = Math.floor(Date.now() / 1000);
  if (Math.abs(nowSec - p.ts) > MAX_CLOCK_SKEW_SEC) return errorResponse(400, "clock_skew");

  const deviceId = p.deviceId.toLowerCase();
  const db = getDb();

  const { data: user } = await db
    .from("users")
    .select("device_id, hmac_key_b64, status")
    .eq("device_id", deviceId)
    .maybeSingle();
  if (!user) return errorResponse(404, "device_not_registered");
  if (user.status === "banned") return errorResponse(403, "banned");

  const ok = await verifyHmac(
    { code: p.code, deviceId: p.deviceId, ts: p.ts },
    body.signature,
    user.hmac_key_b64,
  );
  if (!ok) return errorResponse(401, "bad_signature");

  // 이 device의 최신 미소비 OTP.
  const { data: otp } = await db
    .from("tenant_otp")
    .select("id, tenant_slug, code_hash, expires_at, attempts")
    .eq("device_id", deviceId)
    .is("consumed_at", null)
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle();
  if (!otp) return errorResponse(400, "no_pending_code");
  if (new Date(otp.expires_at).getTime() <= Date.now()) return errorResponse(400, "code_expired");
  if ((otp.attempts ?? 0) >= MAX_ATTEMPTS) return errorResponse(400, "too_many_attempts");

  const codeHash = await sha256Hex(p.code);
  if (codeHash !== otp.code_hash) {
    // 시도 횟수 증가(무차별 대입 완화). best-effort.
    await db.from("tenant_otp").update({ attempts: (otp.attempts ?? 0) + 1 }).eq("id", otp.id);
    return errorResponse(400, "bad_code");
  }

  // 편입 — tenant_id 갱신 + 타 테넌트 길드 자동탈퇴 원자 처리.
  const { data: switchResult, error: rpcErr } = await db.rpc("apply_tenant_switch", {
    p_device: deviceId,
    p_tenant: otp.tenant_slug,
  });
  if (rpcErr) {
    console.error("apply_tenant_switch failed", rpcErr);
    return errorResponse(500, "switch_failed");
  }
  if (switchResult === "already_gated") return errorResponse(409, "already_gated");
  if (switchResult === "not_registered") return errorResponse(404, "device_not_registered");
  if (switchResult !== "ok") return errorResponse(500, "switch_failed");

  // OTP 소비 마킹 — 재사용 방지. best-effort(이미 전환 완료).
  await db.from("tenant_otp").update({ consumed_at: new Date().toISOString() }).eq("id", otp.id);

  // 사내 인증 유도 캠페인 보상 — RP 3000 미수령 행 INSERT(멱등). 인증은 one-way라 여기서 놓치면
  // 재confirm으로 복구 불가(위 already_gated 409)하므로, transient 오류에 대비해 몇 회 재시도해
  // 손실 위험을 낮춘다. tenant_id는 방금 편입된 게이트 테넌트로 귀속(다른 RP 행과 일관). 최종
  // 실패 시에도 전환은 이미 성공했으므로 인증 자체는 성공 처리하고 로그만 남긴다(운영자가
  // reward-grants로 보정). coin 3,000은 클라가 로컬 원장에 별도 지급.
  let rpErr: unknown = null;
  for (let attempt = 0; attempt < 3; attempt++) {
    const { error } = await db.from("rp_rewards").upsert({
      period: TENANT_VERIFY_RP_PERIOD,
      period_type: "monthly",
      tenant_id: otp.tenant_slug,
      device_id: deviceId,
      rank: 1,
      rp_amount: TENANT_VERIFY_RP_AMOUNT,
    }, { onConflict: "period_type,period,device_id", ignoreDuplicates: true });
    if (!error) { rpErr = null; break; }
    rpErr = error;
    if (attempt < 2) await new Promise((r) => setTimeout(r, 150));
  }
  if (rpErr) console.error("tenant verify RP grant failed after retries", rpErr);

  return jsonResponse({ ok: true, tenant: otp.tenant_slug });
});
