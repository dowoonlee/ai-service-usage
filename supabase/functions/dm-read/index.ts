// POST /dm-read — 특정 상대에게서 받은 메시지를 읽음 처리. 요청자 서명.
//
// payload(서명 대상, flat): { deviceId, peerDevice, upToTs, ts }
//   upToTs(초) 이하 created_at의 "peer→나" 미확인 메시지를 read_at=now로.

import { jsonResponse, errorResponse, handleOptions } from "../_shared/cors.ts";
import { getDb } from "../_shared/db.ts";
import { verifyHmac } from "../_shared/hmac.ts";
import { isValidUUID } from "../_shared/validation.ts";

interface ReadPayload {
  deviceId: string;
  peerDevice: string;
  upToTs: number;
  ts: number;
}
interface ReadRequest {
  payload: ReadPayload;
  signature: string;
}
const MAX_CLOCK_SKEW_SEC = 3600;

Deno.serve(async (req: Request) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;
  if (req.method !== "POST") return errorResponse(405, "method_not_allowed");

  let body: ReadRequest;
  try {
    body = await req.json();
  } catch {
    return errorResponse(400, "invalid_json");
  }
  const p = body.payload;
  if (!p || typeof p !== "object") return errorResponse(400, "missing_payload");
  if (!isValidUUID(p.deviceId)) return errorResponse(400, "invalid_device_id");
  if (!isValidUUID(p.peerDevice)) return errorResponse(400, "invalid_peer");
  if (typeof p.upToTs !== "number") return errorResponse(400, "invalid_up_to");
  if (typeof body.signature !== "string" || body.signature.length !== 64) {
    return errorResponse(400, "invalid_signature");
  }
  if (typeof p.ts !== "number") return errorResponse(400, "invalid_ts");
  const nowSec = Math.floor(Date.now() / 1000);
  if (Math.abs(nowSec - p.ts) > MAX_CLOCK_SKEW_SEC) return errorResponse(400, "clock_skew");

  const deviceId = p.deviceId.toLowerCase();
  const peer = p.peerDevice.toLowerCase();
  const db = getDb();

  const { data: user } = await db
    .from("users")
    .select("device_id, hmac_key_b64, status, tenant_id")
    .eq("device_id", deviceId)
    .maybeSingle();
  if (!user) return errorResponse(404, "device_not_registered");
  if (user.status === "banned") return errorResponse(403, "banned");

  const ok = await verifyHmac(
    { deviceId: p.deviceId, peerDevice: p.peerDevice, upToTs: p.upToTs, ts: p.ts },
    body.signature, user.hmac_key_b64);
  if (!ok) return errorResponse(401, "bad_signature");

  const upTo = new Date(p.upToTs * 1000).toISOString();
  const { error } = await db
    .from("direct_messages")
    .update({ read_at: new Date().toISOString() })
    .eq("recipient_device", deviceId)
    .eq("sender_device", peer)
    .eq("tenant_id", user.tenant_id)   // 현재 테넌트 메시지만(§2-4)
    .is("read_at", null)
    .lte("created_at", upTo);
  if (error) {
    console.error("dm-read failed", error);
    return errorResponse(500, "read_failed");
  }
  return jsonResponse({ ok: true });
});
