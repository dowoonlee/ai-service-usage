// POST /delete
// 사용자의 명시적 계정 삭제 요청. HMAC 서명 검증 후 users row 제거 (submissions/abuse_flags
// ON DELETE CASCADE로 같이 사라짐).
//
// payload 구조는 submit과 동일 — 단순화 (delta=0, prevTotal=0). signature는 device_id+ts만
// 사실상 인증하지만 충분.

import { jsonResponse, errorResponse, handleOptions } from "../_shared/cors.ts";
import { getDb } from "../_shared/db.ts";
import { verifyHmac } from "../_shared/hmac.ts";
import { isValidUUID } from "../_shared/validation.ts";

interface DeletePayload {
  deviceId: string;
  delta: number;
  prevTotal: number;
  ts: number;
}
interface DeleteRequest {
  payload: DeletePayload;
  signature: string;
}

const MAX_CLOCK_SKEW_SEC = 3600;

Deno.serve(async (req: Request) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;
  if (req.method !== "POST") return errorResponse(405, "method_not_allowed");

  let body: DeleteRequest;
  try {
    body = await req.json();
  } catch {
    return errorResponse(400, "invalid_json");
  }
  const p = body.payload;
  if (!p || !isValidUUID(p.deviceId)) return errorResponse(400, "invalid_payload");
  if (typeof body.signature !== "string" || body.signature.length !== 64) {
    return errorResponse(400, "invalid_signature");
  }

  const nowSec = Math.floor(Date.now() / 1000);
  if (Math.abs(nowSec - p.ts) > MAX_CLOCK_SKEW_SEC) {
    return errorResponse(400, "clock_skew");
  }

  const db = getDb();
  const { data: user } = await db
    .from("users")
    .select("device_id, hmac_key_b64")
    .eq("device_id", p.deviceId)
    .single();
  if (!user) return errorResponse(404, "device_not_registered");

  const ok = await verifyHmac(
    { delta: p.delta, deviceId: p.deviceId, prevTotal: p.prevTotal, ts: p.ts },
    body.signature,
    user.hmac_key_b64,
  );
  if (!ok) return errorResponse(401, "bad_signature");

  const { error } = await db.from("users").delete().eq("device_id", p.deviceId);
  if (error) {
    console.error("delete failed", error);
    return errorResponse(500, "delete_failed");
  }

  return jsonResponse({ ok: true });
});
