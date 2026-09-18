// POST /guild-visit
// 다른 길드 사무실 "놀러가기" — 같은 테넌트의 임의 길드를 공개 프로젝션으로 읽는다
// (docs/plans/guild-visit.md M1). 멤버십 불필요 — 미가입 온보딩의 "둘러보기"도 이 경로.
//
// guild-info와의 차이(의도적):
//   - inviteCode / deviceId / sentInvites / joinRequests / githubLogin 없음
//   - 멤버 profileJson 없음 — 사무실 렌더에 필요한 대표 펫(kind/variant)·장착 이펙트만 추출.
//     방문은 여러 길드를 훑는 행위라 호출 빈도가 guild-info보다 높고, profile_json은 응답의
//     대부분을 차지한다(guild-leaderboard topMembers와 같은 이유).
//
// payload(서명 대상, flat): { deviceId, guildId, ts }

import { jsonResponse, errorResponse, handleOptions } from "../_shared/cors.ts";
import { getDb } from "../_shared/db.ts";
import { verifyHmac } from "../_shared/hmac.ts";
import { isValidUUID } from "../_shared/validation.ts";
import { resolveTenant } from "../_shared/tenant.ts";
import { TOP_CONTRIBUTORS } from "../_shared/guild_policy.ts";

interface VisitPayload {
  deviceId: string;
  guildId: string;
  ts: number;
}
interface VisitRequest {
  payload: VisitPayload;
  signature: string;
}

const MAX_CLOCK_SKEW_SEC = 3600;

/** profile_json에서 사무실 렌더에 필요한 것만 — 나머지는 버린다. */
function avatarOf(profile: unknown): {
  petKind: string | null;
  petVariant: number;
  equippedEffects: string[];
} {
  const pj = profile as {
    card?: { avatar?: { kind?: unknown; variant?: unknown } };
    equippedEffects?: unknown;
  } | null;
  const avatar = pj?.card?.avatar;
  const effects = Array.isArray(pj?.equippedEffects)
    ? (pj!.equippedEffects as unknown[]).filter((e): e is string => typeof e === "string")
    : [];
  return {
    petKind: typeof avatar?.kind === "string" ? avatar.kind : null,
    petVariant: typeof avatar?.variant === "number" ? avatar.variant : 0,
    equippedEffects: effects,
  };
}

Deno.serve(async (req: Request) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;
  if (req.method !== "POST") return errorResponse(405, "method_not_allowed");

  let body: VisitRequest;
  try {
    body = await req.json();
  } catch {
    return errorResponse(400, "invalid_json");
  }
  const p = body.payload;
  if (!p || typeof p !== "object") return errorResponse(400, "missing_payload");
  if (!isValidUUID(p.deviceId)) return errorResponse(400, "invalid_device_id");
  if (!isValidUUID(p.guildId)) return errorResponse(400, "invalid_guild_id");
  if (typeof body.signature !== "string" || body.signature.length !== 64) {
    return errorResponse(400, "invalid_signature");
  }
  if (typeof p.ts !== "number") return errorResponse(400, "invalid_ts");

  const nowSec = Math.floor(Date.now() / 1000);
  if (Math.abs(nowSec - p.ts) > MAX_CLOCK_SKEW_SEC) {
    return errorResponse(400, "clock_skew");
  }

  const deviceId = p.deviceId.toLowerCase();
  const guildId = p.guildId.toLowerCase();
  const db = getDb();

  const { data: user } = await db
    .from("users")
    .select("device_id, hmac_key_b64, status")
    .eq("device_id", deviceId)
    .maybeSingle();
  if (!user) return errorResponse(404, "device_not_registered");
  if (user.status === "banned") return errorResponse(403, "banned");

  const ok = await verifyHmac(
    { deviceId: p.deviceId, guildId: p.guildId, ts: p.ts },
    body.signature,
    user.hmac_key_b64,
  );
  if (!ok) return errorResponse(401, "bad_signature");

  const { data: guild } = await db
    .from("guilds")
    .select("id, name, tenant_id, leader_device_id, floor_theme, wall_theme, office_furniture, logo, logo_x, logo_y, created_at")
    .eq("id", guildId)
    .maybeSingle();
  if (!guild) return errorResponse(404, "guild_not_found");

  // 테넌트 격리 — 클라는 tenant를 주장할 수 없고 서버가 device_id로만 판정한다 (tenant.md §2).
  const tenant = await resolveTenant(db, deviceId);
  if (!tenant || guild.tenant_id !== tenant) return errorResponse(403, "cross_tenant");

  const { data: memberRows, error: memberErr } = await db
    .from("guild_members")
    .select("device_id, joined_at, users(nickname, profile_json)")
    .eq("guild_id", guild.id)
    .order("joined_at", { ascending: true });
  if (memberErr) {
    console.error("guild visit members fetch failed", memberErr);
    return errorResponse(500, "fetch_failed");
  }

  const { data: vpRows } = await db
    .from("guild_member_monthly_vp")
    .select("device_id, monthly_vp, rn")
    .eq("guild_id", guild.id);
  const vpByDevice = new Map(
    (vpRows ?? []).map((r) => [r.device_id, { vp: Number(r.monthly_vp) || 0, rn: r.rn }]),
  );

  const { data: scoreRow } = await db
    .from("guild_monthly_scores")
    .select("score, rank, member_count")
    .eq("guild_id", guild.id)
    .maybeSingle();

  let isMine = false;
  const members = (memberRows ?? []).map((m) => {
    const u = m.users as unknown as { nickname: string; profile_json: unknown } | null;
    const vp = vpByDevice.get(m.device_id);
    const isMe = m.device_id === deviceId;
    if (isMe) isMine = true;
    return {
      nickname: u?.nickname ?? "(탈퇴)",
      monthlyVP: vp?.vp ?? 0,
      isTopContributor: !!vp && vp.rn <= TOP_CONTRIBUTORS && vp.vp > 0,
      isLeader: m.device_id === guild.leader_device_id,
      isMe,
      joinedAt: m.joined_at,
      ...avatarOf(u?.profile_json ?? null),
    };
  });

  const { data: furnitureRows } = await db
    .from("guild_furniture")
    .select("slot_id, item_kind, users(nickname)")
    .eq("guild_id", guild.id);

  return jsonResponse({
    guild: {
      id: guild.id,
      name: guild.name,
      floorTheme: guild.floor_theme,
      wallTheme: guild.wall_theme,
      officeFurniture: guild.office_furniture,
      logo: guild.logo ?? null,
      logoX: guild.logo_x ?? null,
      logoY: guild.logo_y ?? null,
      createdAt: guild.created_at,
      score: scoreRow ? Number(scoreRow.score) : 0,
      rank: scoreRow ? scoreRow.rank : null,
      memberCount: scoreRow ? scoreRow.member_count : members.length,
      isMine,
    },
    members,
    furniture: (furnitureRows ?? []).map((f) => ({
      slotId: f.slot_id,
      itemKind: f.item_kind,
      donorNickname: (f.users as unknown as { nickname: string } | null)?.nickname ?? null,
    })),
  });
});
