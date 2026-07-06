// POST /guild-info
// 내 길드 상세 — 길드 메타 + 멤버 목록(이번 달 기여 VP·기여 순위·사무실 슬롯·대표 펫)
// + 이번 달 길드 점수/순위. 사무실 씬과 멤버 리스트가 이 응답 하나로 그려진다.
//
// 신원 노출 정책: 멤버 device_id는 요청자가 길드장일 때만 포함 (kick 타겟팅용).
// 일반 멤버 응답에는 닉네임/프로필만.
//
// payload(서명 대상, flat): { deviceId, ts }

import { jsonResponse, errorResponse, handleOptions } from "../_shared/cors.ts";
import { getDb } from "../_shared/db.ts";
import { verifyHmac } from "../_shared/hmac.ts";
import { isValidUUID } from "../_shared/validation.ts";
import { stripBackup } from "../_shared/profile.ts";
import { TOP_CONTRIBUTORS } from "../_shared/guild_policy.ts";

interface InfoPayload {
  deviceId: string;
  ts: number;
}
interface InfoRequest {
  payload: InfoPayload;
  signature: string;
}

const MAX_CLOCK_SKEW_SEC = 3600;

Deno.serve(async (req: Request) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;
  if (req.method !== "POST") return errorResponse(405, "method_not_allowed");

  let body: InfoRequest;
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
    { deviceId: p.deviceId, ts: p.ts },
    body.signature,
    user.hmac_key_b64,
  );
  if (!ok) return errorResponse(401, "bad_signature");

  const { data: membership } = await db
    .from("guild_members")
    .select("guild_id")
    .eq("device_id", deviceId)
    .maybeSingle();
  if (!membership) return errorResponse(404, "not_in_guild");

  const { data: guild } = await db
    .from("guilds")
    .select("id, name, invite_code, leader_device_id, floor_theme, wall_theme, office_furniture, created_at")
    .eq("id", membership.guild_id)
    .maybeSingle();
  if (!guild) return errorResponse(404, "guild_not_found");

  const isLeader = guild.leader_device_id === deviceId;

  // 멤버 + 닉네임/프로필 (FK join). banned/shadow_banned 멤버도 목록에는 표시 —
  // 점수 집계 제외는 뷰(guild_member_monthly_vp)가 처리.
  const { data: memberRows, error: memberErr } = await db
    .from("guild_members")
    .select("device_id, joined_at, office_slot, users(nickname, github_login, profile_json)")
    .eq("guild_id", guild.id)
    .order("joined_at", { ascending: true });
  if (memberErr) {
    console.error("guild info members fetch failed", memberErr);
    return errorResponse(500, "fetch_failed");
  }

  // 멤버별 이번 달 VP + 길드 내 기여 순위 (rn <= TOP_CONTRIBUTORS = 점수 반영 ★).
  const { data: vpRows } = await db
    .from("guild_member_monthly_vp")
    .select("device_id, monthly_vp, rn")
    .eq("guild_id", guild.id);
  const vpByDevice = new Map(
    (vpRows ?? []).map((r) => [r.device_id, { vp: Number(r.monthly_vp) || 0, rn: r.rn }]),
  );

  // 길드 점수/순위.
  const { data: scoreRow } = await db
    .from("guild_monthly_scores")
    .select("score, rank, member_count")
    .eq("guild_id", guild.id)
    .maybeSingle();

  const members = (memberRows ?? []).map((m) => {
    const u = m.users as unknown as {
      nickname: string;
      github_login: string | null;
      profile_json: unknown;
    } | null;
    const vp = vpByDevice.get(m.device_id);
    return {
      nickname: u?.nickname ?? "(탈퇴)",
      monthlyVP: vp?.vp ?? 0,
      // 점수 반영 여부 — VP 0이면 rn이 5 안이어도 기여로 치지 않음 (전원 0인 신생 길드에서
      // 전원 ★이 되는 것 방지).
      isTopContributor: !!vp && vp.rn <= TOP_CONTRIBUTORS && vp.vp > 0,
      officeSlot: m.office_slot,
      isLeader: m.device_id === guild.leader_device_id,
      isMe: m.device_id === deviceId,
      joinedAt: m.joined_at,
      githubLogin: u?.github_login ?? null,
      profileJson: stripBackup(u?.profile_json ?? null),
      // kick 타겟팅용 — 길드장에게만 노출.
      ...(isLeader ? { deviceId: m.device_id } : {}),
    };
  });

  // P2b 데코 — 기부자 명판용 닉네임 embed (purchased_by FK → users. 탈퇴 시 SET NULL → null).
  const { data: furnitureRows } = await db
    .from("guild_furniture")
    .select("slot_id, item_kind, purchased_at, users(nickname)")
    .eq("guild_id", guild.id);

  return jsonResponse({
    guild: {
      id: guild.id,
      name: guild.name,
      inviteCode: guild.invite_code,   // 멤버 전원 공개 (공유용). 재발급은 길드장만.
      isLeader,
      floorTheme: guild.floor_theme,
      wallTheme: guild.wall_theme,
      officeFurniture: guild.office_furniture,   // 가구 자유 배치 직렬화 — 클라 렌더 입력

      createdAt: guild.created_at,
      score: scoreRow ? Number(scoreRow.score) : 0,
      rank: scoreRow ? scoreRow.rank : null,
      memberCount: scoreRow ? scoreRow.member_count : members.length,
    },
    members,
    // 클라이언트 모델(GuildFurnitureItem)과 동일한 camelCase로 매핑 — DB row 그대로 내보내지 않는다.
    furniture: (furnitureRows ?? []).map((f) => ({
      slotId: f.slot_id,
      itemKind: f.item_kind,
      donorNickname: (f.users as unknown as { nickname: string } | null)?.nickname ?? null,
    })),
  });
});
