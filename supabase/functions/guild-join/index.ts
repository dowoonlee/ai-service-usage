// POST /guild-join
// 초대 코드로 길드 가입. HMAC 검증, 1인 1길드(UNIQUE), 탈퇴/추방 후 쿨다운 검사.
//
// payload(서명 대상, flat): { deviceId, inviteCode, ts }

import { jsonResponse, errorResponse, handleOptions } from "../_shared/cors.ts";
import { getDb } from "../_shared/db.ts";
import { verifyHmac } from "../_shared/hmac.ts";
import { isValidUUID } from "../_shared/validation.ts";
import { INVITE_CODE_LEN } from "../_shared/guild_policy.ts";

interface JoinPayload {
  deviceId: string;
  inviteCode: string;
  ts: number;
}
interface JoinRequest {
  payload: JoinPayload;
  signature: string;
}

const MAX_CLOCK_SKEW_SEC = 3600;

Deno.serve(async (req: Request) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;
  if (req.method !== "POST") return errorResponse(405, "method_not_allowed");

  let body: JoinRequest;
  try {
    body = await req.json();
  } catch {
    return errorResponse(400, "invalid_json");
  }
  const p = body.payload;
  if (!p || typeof p !== "object") return errorResponse(400, "missing_payload");
  if (!isValidUUID(p.deviceId)) return errorResponse(400, "invalid_device_id");
  if (typeof p.inviteCode !== "string" || p.inviteCode.length !== INVITE_CODE_LEN) {
    return errorResponse(400, "invalid_invite_code");
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
    { deviceId: p.deviceId, inviteCode: p.inviteCode, ts: p.ts },
    body.signature,
    user.hmac_key_b64,
  );
  if (!ok) return errorResponse(401, "bad_signature");

  // 쿨다운 검사 — 만료된 row는 무시 (정리는 upsert가 자연히 덮어씀).
  const { data: cooldown } = await db
    .from("guild_join_cooldowns")
    .select("until")
    .eq("device_id", deviceId)
    .maybeSingle();
  if (cooldown && new Date(cooldown.until).getTime() > Date.now()) {
    return jsonResponse(
      { error: "join_cooldown", until: cooldown.until },
      { status: 403 },
    );
  }

  // 초대 코드는 대문자 셋으로 발급 — 입력 관용을 위해 대문자로 정규화 후 조회.
  const { data: guild } = await db
    .from("guilds")
    .select("id, name")
    .eq("invite_code", p.inviteCode.toUpperCase())
    .maybeSingle();
  if (!guild) return errorResponse(404, "invalid_code");

  const { error: insErr } = await db
    .from("guild_members")
    .insert({ guild_id: guild.id, device_id: deviceId });
  if (insErr) {
    // UNIQUE(device_id) = 이미 어딘가 가입 (본 길드 포함).
    if (insErr.code === "23505") return errorResponse(409, "already_in_guild");
    console.error("guild join insert failed", insErr);
    return errorResponse(500, "join_failed");
  }

  const { count: memberCount } = await db
    .from("guild_members")
    .select("device_id", { count: "exact", head: true })
    .eq("guild_id", guild.id);

  return jsonResponse({
    guildId: guild.id,
    name: guild.name,
    memberCount: memberCount ?? 1,
  });
});
