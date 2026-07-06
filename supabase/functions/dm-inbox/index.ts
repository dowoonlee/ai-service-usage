// POST /dm-inbox — 내 쪽지 스레드 요약 (상대별 최근 1건 + 미확인 수). 요청자 서명.
//
// payload(서명 대상, flat): { deviceId, ts }
//
// 서버는 나와 얽힌 메시지(발신/수신)를 상대(peer)별로 묶어 최근 1건을 요약해 준다. 본문은
// E2EE라 서버가 못 읽으므로 ciphertext 그대로 내려주고, 클라가 복호(수신분)하거나 로컬 echo
// (발신분)로 미리보기를 만든다. 삭제(tombstone)된 내 쪽은 제외.

import { jsonResponse, errorResponse, handleOptions } from "../_shared/cors.ts";
import { getDb } from "../_shared/db.ts";
import { verifyHmac } from "../_shared/hmac.ts";
import { isValidUUID } from "../_shared/validation.ts";

interface InboxPayload {
  deviceId: string;
  ts: number;
}
interface InboxRequest {
  payload: InboxPayload;
  signature: string;
}
const MAX_CLOCK_SKEW_SEC = 3600;
const SCAN_LIMIT = 500; // 최근 메시지 스캔 상한 (스레드 요약 조립용)

Deno.serve(async (req: Request) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;
  if (req.method !== "POST") return errorResponse(405, "method_not_allowed");

  let body: InboxRequest;
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
    { deviceId: p.deviceId, ts: p.ts }, body.signature, user.hmac_key_b64);
  if (!ok) return errorResponse(401, "bad_signature");

  // 받은 것 + 보낸 것 (각각 내 쪽 tombstone 제외), 최근 순.
  const [{ data: received }, { data: sent }] = await Promise.all([
    db.from("direct_messages")
      .select("id, sender_device, ciphertext, sender_id_pub, created_at, read_at")
      .eq("recipient_device", deviceId).eq("del_recipient", false)
      .order("created_at", { ascending: false }).limit(SCAN_LIMIT),
    db.from("direct_messages")
      .select("id, recipient_device, ciphertext, sender_id_pub, created_at")
      .eq("sender_device", deviceId).eq("del_sender", false)
      .order("created_at", { ascending: false }).limit(SCAN_LIMIT),
  ]);

  // peer별 최근 1건 + 미확인 수 집계.
  interface Thread {
    peerDevice: string;
    lastId: string; lastCiphertext: string; lastSenderIdPub: string;
    lastFromMe: boolean; lastAt: string; unreadCount: number;
  }
  const threads = new Map<string, Thread>();
  const bump = (peer: string, m: {
    id: string; ciphertext: string; sender_id_pub: string; created_at: string; fromMe: boolean;
  }) => {
    const cur = threads.get(peer);
    if (!cur || m.created_at > cur.lastAt) {
      threads.set(peer, {
        peerDevice: peer, lastId: m.id, lastCiphertext: m.ciphertext,
        lastSenderIdPub: m.sender_id_pub, lastFromMe: m.fromMe, lastAt: m.created_at,
        unreadCount: cur?.unreadCount ?? 0,
      });
    }
  };
  for (const m of received ?? []) {
    bump(m.sender_device, { ...m, fromMe: false });
    if (!m.read_at) {
      const t = threads.get(m.sender_device);
      if (t) t.unreadCount += 1;
    }
  }
  for (const m of sent ?? []) bump(m.recipient_device, { ...m, fromMe: true });

  const list = [...threads.values()].sort((a, b) => (a.lastAt < b.lastAt ? 1 : -1));

  // peer 닉네임 + 공개키 일괄 조회.
  const peerIds = list.map((t) => t.peerDevice);
  const nickById = new Map<string, string>();
  const pubById = new Map<string, string>();
  if (peerIds.length > 0) {
    const [{ data: usrs }, { data: keys }] = await Promise.all([
      db.from("users").select("device_id, nickname").in("device_id", peerIds),
      db.from("user_keys").select("device_id, x25519_pub").in("device_id", peerIds),
    ]);
    for (const u of usrs ?? []) nickById.set(u.device_id, u.nickname);
    for (const k of keys ?? []) pubById.set(k.device_id, k.x25519_pub);
  }

  return jsonResponse({
    threads: list.map((t) => ({
      peerDevice: t.peerDevice,
      peerNickname: nickById.get(t.peerDevice) ?? null,
      peerIdPub: pubById.get(t.peerDevice) ?? null,
      lastId: t.lastId,
      lastCiphertext: t.lastCiphertext,
      lastSenderIdPub: t.lastSenderIdPub,
      lastFromMe: t.lastFromMe,
      lastAt: t.lastAt,
      unreadCount: t.unreadCount,
    })),
  });
});
