// POST /dm-thread — 특정 상대와의 메시지 목록 (양방향, 최근 N건). 요청자 서명.
//
// payload(서명 대상, flat): { deviceId, peerDevice, ts }
//
// 서버는 (나, peer) 쌍의 메시지를 시간순으로 내려준다(각각 내 쪽 tombstone 제외). 본문은
// E2EE — 클라가 수신분은 복호, 발신분은 로컬 echo로 표시(HPKE는 수신자만 복호 가능).

import { jsonResponse, errorResponse, handleOptions } from "../_shared/cors.ts";
import { getDb } from "../_shared/db.ts";
import { verifyHmac } from "../_shared/hmac.ts";
import { isValidUUID } from "../_shared/validation.ts";
import { DM_THREAD_PAGE } from "../_shared/dm_policy.ts";

interface ThreadPayload {
  deviceId: string;
  peerDevice: string;
  ts: number;
}
interface ThreadRequest {
  payload: ThreadPayload;
  signature: string;
}
const MAX_CLOCK_SKEW_SEC = 3600;

Deno.serve(async (req: Request) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;
  if (req.method !== "POST") return errorResponse(405, "method_not_allowed");

  let body: ThreadRequest;
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
    .from("users")
    .select("device_id, hmac_key_b64, status")
    .eq("device_id", deviceId)
    .maybeSingle();
  if (!user) return errorResponse(404, "device_not_registered");
  if (user.status === "banned") return errorResponse(403, "banned");

  const ok = await verifyHmac(
    { deviceId: p.deviceId, peerDevice: p.peerDevice, ts: p.ts },
    body.signature, user.hmac_key_b64);
  if (!ok) return errorResponse(401, "bad_signature");

  // 테넌트 필터 없음 — 전환 후에도 본인 과거 스레드 열람 가능(§2-4 재검토). 발신 차단은 dm-send가 담당.
  const [{ data: received }, { data: sent }] = await Promise.all([
    db.from("direct_messages")
      .select("id, ciphertext, sender_id_pub, created_at, read_at")
      .eq("recipient_device", deviceId).eq("sender_device", peer).eq("del_recipient", false)
      .order("created_at", { ascending: false }).limit(DM_THREAD_PAGE),
    db.from("direct_messages")
      .select("id, ciphertext, sender_id_pub, created_at")
      .eq("sender_device", deviceId).eq("recipient_device", peer).eq("del_sender", false)
      .order("created_at", { ascending: false }).limit(DM_THREAD_PAGE),
  ]);

  const msgs = [
    ...(received ?? []).map((m) => ({
      id: m.id, fromMe: false, ciphertext: m.ciphertext, senderIdPub: m.sender_id_pub,
      createdAt: m.created_at, readAt: m.read_at,
    })),
    ...(sent ?? []).map((m) => ({
      id: m.id, fromMe: true, ciphertext: m.ciphertext, senderIdPub: m.sender_id_pub,
      createdAt: m.created_at, readAt: null,
    })),
  ].sort((a, b) => (a.createdAt < b.createdAt ? -1 : 1)) // 오래된 → 최신
   .slice(-DM_THREAD_PAGE);

  const { data: peerUser } = await db
    .from("users").select("nickname").eq("device_id", peer).maybeSingle();

  return jsonResponse({ peerNickname: peerUser?.nickname ?? null, messages: msgs });
});
