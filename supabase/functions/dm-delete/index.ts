// POST /dm-delete — 특정 상대와의 대화를 내 쪽에서 삭제(tombstone). 요청자 HMAC 서명.
//
// payload(서명 대상, flat): { deviceId, peerDevice, ts }
//   내가 보낸 것은 del_sender=true, 받은 것은 del_recipient=true 로 표시(내 인박스/스레드에서 제외).
//   상대는 자기 사본을 그대로 보유("나만 삭제"). 양측이 모두 삭제한 메시지는 물리 삭제(DB 정리).

import { jsonResponse, errorResponse, handleOptions } from "../_shared/cors.ts";
import { getDb } from "../_shared/db.ts";
import { verifyHmac } from "../_shared/hmac.ts";
import { isValidUUID } from "../_shared/validation.ts";

interface DeletePayload {
  deviceId: string;
  peerDevice: string;
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
  if (!p || typeof p !== "object") return errorResponse(400, "missing_payload");
  if (!isValidUUID(p.deviceId)) return errorResponse(400, "invalid_device_id");
  if (!isValidUUID(p.peerDevice)) return errorResponse(400, "invalid_peer");
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
    .from("users").select("device_id, hmac_key_b64, status").eq("device_id", deviceId).maybeSingle();
  if (!user) return errorResponse(404, "device_not_registered");
  if (user.status === "banned") return errorResponse(403, "banned");

  const ok = await verifyHmac(
    { deviceId: p.deviceId, peerDevice: p.peerDevice, ts: p.ts }, body.signature, user.hmac_key_b64);
  if (!ok) return errorResponse(401, "bad_signature");

  // 내 쪽 tombstone — 받은 것(peer→나) / 보낸 것(나→peer) 각각.
  const [rRes, sRes] = await Promise.all([
    db.from("direct_messages").update({ del_recipient: true })
      .eq("recipient_device", deviceId).eq("sender_device", peer).eq("del_recipient", false),
    db.from("direct_messages").update({ del_sender: true })
      .eq("sender_device", deviceId).eq("recipient_device", peer).eq("del_sender", false),
  ]);
  if (rRes.error || sRes.error) {
    console.error("dm-delete tombstone failed", rRes.error ?? sRes.error);
    return errorResponse(500, "delete_failed");
  }

  // 양측 모두 삭제한 메시지는 물리 삭제(두 방향 각각).
  await Promise.all([
    db.from("direct_messages").delete()
      .eq("del_sender", true).eq("del_recipient", true)
      .eq("sender_device", deviceId).eq("recipient_device", peer),
    db.from("direct_messages").delete()
      .eq("del_sender", true).eq("del_recipient", true)
      .eq("sender_device", peer).eq("recipient_device", deviceId),
  ]);

  return jsonResponse({ ok: true });
});
