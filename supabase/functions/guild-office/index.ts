// POST /guild-office
// 사무실 self-액션: 내 스팟 선택/이동/비우기. 스팟은 선착순 점유 —
// UNIQUE(guild_id, office_slot) 위반 시 409 slot_taken (클라는 토스트 + 재로드).
// P2b에서 데코 배치/제거·테마 변경 액션이 여기에 추가된다 (docs/plans/guild.md §3).
//
// payload(서명 대상, flat): { deviceId, slot, ts }
//   - slot: 0..11 = 해당 스팟 점유, -1 = 비우기 (HMAC canonical 형태를 위해 null 대신 -1)

import { jsonResponse, errorResponse, handleOptions } from "../_shared/cors.ts";
import { getDb } from "../_shared/db.ts";
import { verifyHmac } from "../_shared/hmac.ts";
import { isValidUUID } from "../_shared/validation.ts";
import { OFFICE_SLOT_COUNT } from "../_shared/guild_policy.ts";

interface OfficePayload {
  deviceId: string;
  slot: number;
  ts: number;
}
interface OfficeRequest {
  payload: OfficePayload;
  signature: string;
}

const MAX_CLOCK_SKEW_SEC = 3600;

Deno.serve(async (req: Request) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;
  if (req.method !== "POST") return errorResponse(405, "method_not_allowed");

  let body: OfficeRequest;
  try {
    body = await req.json();
  } catch {
    return errorResponse(400, "invalid_json");
  }
  const p = body.payload;
  if (!p || typeof p !== "object") return errorResponse(400, "missing_payload");
  if (!isValidUUID(p.deviceId)) return errorResponse(400, "invalid_device_id");
  if (
    typeof p.slot !== "number" || !Number.isInteger(p.slot) ||
    p.slot < -1 || p.slot >= OFFICE_SLOT_COUNT
  ) {
    return errorResponse(400, "invalid_slot");
  }
  if (typeof body.signature !== "string" || body.signature.length !== 64) {
    return errorResponse(400, "invalid_signature");
  }
  if (typeof p.ts !== "number") return errorResponse(400, "invalid_ts");

  const nowSec = Math.floor(Date.now() / 1000);
  if (Math.abs(nowSec - p.ts) > MAX_CLOCK_SKEW_SEC) {
    return errorResponse(400, "clock_skew");
  }

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
    { deviceId: p.deviceId, slot: p.slot, ts: p.ts },
    body.signature,
    user.hmac_key_b64,
  );
  if (!ok) return errorResponse(401, "bad_signature");

  const { data: membership } = await db
    .from("guild_members")
    .select("guild_id, office_slot")
    .eq("device_id", deviceId)
    .maybeSingle();
  if (!membership) return errorResponse(404, "not_in_guild");

  const newSlot = p.slot === -1 ? null : p.slot;
  const { error: updErr } = await db
    .from("guild_members")
    .update({ office_slot: newSlot })
    .eq("device_id", deviceId);
  if (updErr) {
    // partial UNIQUE(guild_id, office_slot) 위반 = 방금 다른 멤버가 선점.
    if (updErr.code === "23505") return errorResponse(409, "slot_taken");
    console.error("guild office update failed", updErr);
    return errorResponse(500, "office_failed");
  }

  return jsonResponse({ ok: true, slot: newSlot });
});
