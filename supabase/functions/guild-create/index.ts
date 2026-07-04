// POST /guild-create
// 길드 창설. HMAC 검증, 1인 1길드, 길드명 case-insensitive unique, IP rate-limit.
//
// 생성권(코인)은 클라이언트 로컬 경제라 서버가 검증하지 않는다 — 서버 측 실질 가드는
// IP rate-limit + 가입 쿨다운. 쿨다운은 join뿐 아니라 create에도 적용한다 (탈퇴 직후
// 새 길드를 만들어 월간 점수판을 오가는 것도 이적의 변형이므로).
//
// payload(서명 대상, flat): { deviceId, name, ts }

import { jsonResponse, errorResponse, handleOptions } from "../_shared/cors.ts";
import { getDb } from "../_shared/db.ts";
import { verifyHmac } from "../_shared/hmac.ts";
import { isValidUUID } from "../_shared/validation.ts";
import {
  CREATE_IP_MAX,
  CREATE_IP_WINDOW_SEC,
  generateInviteCode,
  isValidGuildName,
} from "../_shared/guild_policy.ts";

interface CreatePayload {
  deviceId: string;
  name: string;
  ts: number;
}
interface CreateRequest {
  payload: CreatePayload;
  signature: string;
}

const MAX_CLOCK_SKEW_SEC = 3600;

function clientIp(req: Request): string | null {
  const xff = req.headers.get("x-forwarded-for");
  if (xff) {
    const first = xff.split(",")[0].trim();
    if (first) return first;
  }
  return req.headers.get("x-real-ip");
}

Deno.serve(async (req: Request) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;
  if (req.method !== "POST") return errorResponse(405, "method_not_allowed");

  let body: CreateRequest;
  try {
    body = await req.json();
  } catch {
    return errorResponse(400, "invalid_json");
  }
  const p = body.payload;
  if (!p || typeof p !== "object") return errorResponse(400, "missing_payload");
  if (!isValidUUID(p.deviceId)) return errorResponse(400, "invalid_device_id");
  if (!isValidGuildName(p.name)) return errorResponse(400, "invalid_guild_name");
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
    { deviceId: p.deviceId, name: p.name, ts: p.ts },
    body.signature,
    user.hmac_key_b64,
  );
  if (!ok) return errorResponse(401, "bad_signature");

  // 1인 1길드 선검사 (race는 아래 guild_members UNIQUE가 최종 방어).
  const { data: existingMembership } = await db
    .from("guild_members")
    .select("guild_id")
    .eq("device_id", deviceId)
    .maybeSingle();
  if (existingMembership) return errorResponse(409, "already_in_guild");

  // 가입 쿨다운 — create에도 적용 (헤더 주석 참조).
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

  // IP rate-limit.
  const ip = clientIp(req);
  if (ip) {
    const since = new Date(Date.now() - CREATE_IP_WINDOW_SEC * 1000).toISOString();
    const { count } = await db
      .from("guild_create_attempts")
      .select("id", { count: "exact", head: true })
      .eq("ip", ip)
      .gte("attempted_at", since);
    if ((count ?? 0) >= CREATE_IP_MAX) {
      return errorResponse(429, "rate_limited");
    }
  }

  // 길드명 충돌 선검사 — UNIQUE 인덱스가 race 최종 방어.
  const normalized = p.name.toLowerCase();
  const { data: nameClash } = await db
    .from("guilds")
    .select("id")
    .eq("name_normalized", normalized)
    .maybeSingle();
  if (nameClash) return errorResponse(409, "name_taken");

  // 초대 코드 충돌은 확률적으로 희박하지만 재시도로 흡수.
  let guildId: string | null = null;
  let inviteCode = "";
  for (let attempt = 0; attempt < 3 && guildId === null; attempt++) {
    inviteCode = generateInviteCode();
    const { data: inserted, error: insErr } = await db
      .from("guilds")
      .insert({
        name: p.name,
        name_normalized: normalized,
        invite_code: inviteCode,
        leader_device_id: deviceId,
      })
      .select("id")
      .single();
    if (insErr) {
      if (insErr.code === "23505") {
        // name/invite_code 어느 쪽 UNIQUE인지 구분 — 이름 충돌이면 재시도 무의미.
        const { data: recheck } = await db
          .from("guilds")
          .select("id")
          .eq("name_normalized", normalized)
          .maybeSingle();
        if (recheck) return errorResponse(409, "name_taken");
        continue; // invite_code 충돌 → 새 코드로 재시도
      }
      console.error("guild insert failed", insErr);
      return errorResponse(500, "create_failed");
    }
    guildId = inserted.id;
  }
  if (!guildId) return errorResponse(500, "create_failed");

  // 창설자를 멤버로 등록. UNIQUE(device_id) 위반 = 위 선검사 이후 다른 길드에 가입한 race
  // → 만든 길드를 되돌리고 409.
  const { error: memberErr } = await db
    .from("guild_members")
    .insert({ guild_id: guildId, device_id: deviceId });
  if (memberErr) {
    await db.from("guilds").delete().eq("id", guildId);
    if (memberErr.code === "23505") return errorResponse(409, "already_in_guild");
    console.error("guild member insert failed", memberErr);
    return errorResponse(500, "create_failed");
  }

  // 성공만 rate-limit 카운트 (register 패턴). best-effort.
  if (ip) {
    await db.from("guild_create_attempts").insert({ ip });
  }

  return jsonResponse({
    guildId,
    name: p.name,
    inviteCode,
  });
});
