// POST /dm-keys — 신원 공개키 게시/조회 (E2EE 쪽지용). 모두 요청자 HMAC 서명.
//
// payload(서명 대상, flat): { action, deviceId, [x25519Pub|targetNickname,] ts }
//   - publish: { action:"publish", deviceId, x25519Pub, ts }  → 내 공개키 upsert(신규/rotate)
//   - fetch:   { action:"fetch", deviceId, targetNickname, ts } → 상대 공개키 반환
//   키는 액션별로만 직렬화 — canonical 재현도 present-only(guild-manage 패턴).

import { jsonResponse, errorResponse, handleOptions } from "../_shared/cors.ts";
import { getDb } from "../_shared/db.ts";
import { verifyHmac } from "../_shared/hmac.ts";
import { isValidUUID } from "../_shared/validation.ts";
import { DM_X25519_PUB_LEN } from "../_shared/dm_policy.ts";

type KeysAction = "publish" | "fetch";
const KEYS_ACTIONS: ReadonlySet<string> = new Set(["publish", "fetch"]);
const MAX_CLOCK_SKEW_SEC = 3600;

interface KeysPayload {
  action: KeysAction;
  deviceId: string;
  x25519Pub?: string;
  targetNickname?: string;
  ts: number;
}
interface KeysRequest {
  payload: KeysPayload;
  signature: string;
}

Deno.serve(async (req: Request) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;
  if (req.method !== "POST") return errorResponse(405, "method_not_allowed");

  let body: KeysRequest;
  try {
    body = await req.json();
  } catch {
    return errorResponse(400, "invalid_json");
  }
  const p = body.payload;
  if (!p || typeof p !== "object") return errorResponse(400, "missing_payload");
  if (!isValidUUID(p.deviceId)) return errorResponse(400, "invalid_device_id");
  if (!KEYS_ACTIONS.has(p.action)) return errorResponse(400, "invalid_action");
  if (p.action === "publish") {
    if (typeof p.x25519Pub !== "string" || p.x25519Pub.length !== DM_X25519_PUB_LEN) {
      return errorResponse(400, "invalid_pubkey");
    }
  }
  if (p.action === "fetch") {
    const n = p.targetNickname;
    if (typeof n !== "string" || n.length < 3 || n.length > 24) {
      return errorResponse(400, "invalid_nickname");
    }
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
    .select("device_id, hmac_key_b64, status")
    .eq("device_id", deviceId)
    .maybeSingle();
  if (!user) return errorResponse(404, "device_not_registered");
  if (user.status === "banned") return errorResponse(403, "banned");

  const verifyObj: Record<string, unknown> = { action: p.action, deviceId: p.deviceId, ts: p.ts };
  if (typeof p.x25519Pub === "string") verifyObj.x25519Pub = p.x25519Pub;
  if (typeof p.targetNickname === "string") verifyObj.targetNickname = p.targetNickname;
  const ok = await verifyHmac(verifyObj, body.signature, user.hmac_key_b64);
  if (!ok) return errorResponse(401, "bad_signature");

  if (p.action === "publish") {
    const { error } = await db.from("user_keys").upsert({
      device_id: deviceId,
      x25519_pub: p.x25519Pub,
      updated_at: new Date().toISOString(),
    });
    if (error) {
      console.error("dm-keys publish failed", error);
      return errorResponse(500, "publish_failed");
    }
    return jsonResponse({ ok: true });
  }

  // fetch — 닉네임 → device → 공개키. 키 미게시(쪽지 미시작) 유저는 404 no_key.
  const { data: target } = await db
    .from("users")
    .select("device_id")
    .eq("nickname_normalized", p.targetNickname!.trim().toLowerCase())
    .maybeSingle();
  if (!target) return errorResponse(404, "no_key");   // 존재 여부 뭉갬 (프라이버시)
  const { data: key } = await db
    .from("user_keys")
    .select("x25519_pub")
    .eq("device_id", target.device_id)
    .maybeSingle();
  if (!key) return errorResponse(404, "no_key");
  return jsonResponse({ deviceId: target.device_id, x25519Pub: key.x25519_pub });
});
