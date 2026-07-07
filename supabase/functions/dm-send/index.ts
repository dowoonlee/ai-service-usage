// POST /dm-send — 암호화된 쪽지 발신. 본문은 E2EE라 서버는 ciphertext를 저장만 한다.
//
// payload(서명 대상, flat): { deviceId, targetNickname, ciphertext, senderIdPub, ts }
//   ciphertext = base64(version || encapsulatedKey || ct). 서버 불투명.
//   반려 사유는 프라이버시상 뭉갠다(cannot_send) — 존재/키/차단/수신설정을 구분 노출하지 않음.

import { jsonResponse, errorResponse, handleOptions } from "../_shared/cors.ts";
import { getDb } from "../_shared/db.ts";
import { verifyHmac } from "../_shared/hmac.ts";
import { isValidUUID } from "../_shared/validation.ts";
import {
  DM_CIPHERTEXT_MAX,
  DM_MAX_PER_DAY,
  DM_MAX_NEW_PEERS_PER_DAY,
  DM_X25519_PUB_LEN,
} from "../_shared/dm_policy.ts";

interface SendPayload {
  deviceId: string;
  targetNickname: string;
  ciphertext: string;
  senderIdPub: string;
  ts: number;
}
interface SendRequest {
  payload: SendPayload;
  signature: string;
}
const MAX_CLOCK_SKEW_SEC = 3600;

Deno.serve(async (req: Request) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;
  if (req.method !== "POST") return errorResponse(405, "method_not_allowed");

  let body: SendRequest;
  try {
    body = await req.json();
  } catch {
    return errorResponse(400, "invalid_json");
  }
  const p = body.payload;
  if (!p || typeof p !== "object") return errorResponse(400, "missing_payload");
  if (!isValidUUID(p.deviceId)) return errorResponse(400, "invalid_device_id");
  if (typeof p.targetNickname !== "string" || p.targetNickname.length < 3 || p.targetNickname.length > 24) {
    return errorResponse(400, "invalid_nickname");
  }
  if (typeof p.ciphertext !== "string" || p.ciphertext.length === 0 || p.ciphertext.length > DM_CIPHERTEXT_MAX) {
    return errorResponse(400, "invalid_ciphertext");
  }
  if (typeof p.senderIdPub !== "string" || p.senderIdPub.length !== DM_X25519_PUB_LEN) {
    return errorResponse(400, "invalid_pubkey");
  }
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
    .select("device_id, hmac_key_b64, status, tenant_id")
    .eq("device_id", deviceId)
    .maybeSingle();
  if (!user) return errorResponse(404, "device_not_registered");
  if (user.status === "banned") return errorResponse(403, "banned");

  const ok = await verifyHmac(
    { deviceId: p.deviceId, targetNickname: p.targetNickname, ciphertext: p.ciphertext,
      senderIdPub: p.senderIdPub, ts: p.ts },
    body.signature,
    user.hmac_key_b64,
  );
  if (!ok) return errorResponse(401, "bad_signature");

  // 수신자 해석 (닉네임 → device).
  const { data: recipient } = await db
    .from("users")
    .select("device_id, status, tenant_id")
    .eq("nickname_normalized", p.targetNickname.trim().toLowerCase())
    .maybeSingle();
  if (!recipient || recipient.status === "banned") return errorResponse(404, "cannot_send");
  // 다른 테넌트 사용자는 이 테넌트에서 "존재하지 않음"과 동일 취급 — 존재 노출 없이 격리(프라이버시 모델 유지, §4).
  if (recipient.tenant_id !== user.tenant_id) return errorResponse(404, "cannot_send");
  if (recipient.device_id === deviceId) return errorResponse(400, "cannot_send_self");

  // 수신자가 키를 게시했어야 함(쪽지 시작 유저).
  const { data: rKey } = await db
    .from("user_keys")
    .select("device_id")
    .eq("device_id", recipient.device_id)
    .maybeSingle();
  if (!rKey) return errorResponse(409, "cannot_send");

  // 차단: 수신자가 나를 차단했으면 거부.
  const { data: blocked } = await db
    .from("dm_blocks")
    .select("blocker_device")
    .eq("blocker_device", recipient.device_id)
    .eq("blocked_device", deviceId)
    .maybeSingle();
  if (blocked) return errorResponse(409, "cannot_send");

  // 수신 정책 allow_from — 없으면 기본 anyone.
  const { data: settings } = await db
    .from("dm_settings")
    .select("allow_from")
    .eq("device_id", recipient.device_id)
    .maybeSingle();
  const allowFrom = settings?.allow_from ?? "anyone";
  if (allowFrom === "none") return errorResponse(409, "cannot_send");
  if (allowFrom === "guild") {
    // 같은 길드 멤버만. 둘 다 멤버이고 guild_id 일치해야.
    const { data: rows } = await db
      .from("guild_members")
      .select("device_id, guild_id")
      .in("device_id", [deviceId, recipient.device_id]);
    const mine = rows?.find((r) => r.device_id === deviceId)?.guild_id;
    const theirs = rows?.find((r) => r.device_id === recipient.device_id)?.guild_id;
    if (!mine || !theirs || mine !== theirs) return errorResponse(409, "cannot_send");
  }

  // 레이트리밋 — 24h 발신 총량 + 하루 서로 다른 상대 수.
  const dayAgo = new Date(Date.now() - 24 * 3600 * 1000).toISOString();
  const { count: sentToday } = await db
    .from("direct_messages")
    .select("id", { count: "exact", head: true })
    .eq("sender_device", deviceId)
    .gt("created_at", dayAgo);
  if ((sentToday ?? 0) >= DM_MAX_PER_DAY) return errorResponse(429, "rate_limited");

  const { data: recentPeers } = await db
    .from("direct_messages")
    .select("recipient_device")
    .eq("sender_device", deviceId)
    .gt("created_at", dayAgo);
  const distinct = new Set((recentPeers ?? []).map((r) => r.recipient_device));
  if (!distinct.has(recipient.device_id) && distinct.size >= DM_MAX_NEW_PEERS_PER_DAY) {
    return errorResponse(429, "rate_limited");
  }

  const { data: inserted, error: insErr } = await db
    .from("direct_messages")
    .insert({
      sender_device: deviceId,
      recipient_device: recipient.device_id,
      ciphertext: p.ciphertext,
      sender_id_pub: p.senderIdPub,
      tenant_id: user.tenant_id,   // 발·수신 동일 테넌트(위에서 검증). 스레드 조회 필터의 기준.
    })
    .select("id, created_at")
    .single();
  if (insErr) {
    console.error("dm-send insert failed", insErr);
    return errorResponse(500, "send_failed");
  }
  return jsonResponse({ id: inserted.id, createdAt: inserted.created_at });
});
