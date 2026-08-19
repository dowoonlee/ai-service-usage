// GET /guild-leaderboard?deviceId=<uuid>
// 길드 월간 랭킹 — guild_monthly_scores 뷰 (멤버 상위 5명 VP 합산, KST 월 경계).
// deviceId 없이도 조회 가능 (미가입 온보딩의 "구경" 리스트). deviceId가 멤버면 myGuild 반환.
// 1인 길드도 그대로 노출 (기획 확정 사항).
//
// P2a: 직전 달 finalize를 lazy 트리거 (첫 호출자가 실행, EXISTS 가드로 이후 no-op) +
// 직전 달 길드 시상대(previousMonth) 반환. 보상 수령은 개인 leaderboard의
// pendingRpReward → claim-reward 경로를 그대로 탄다 (rp_rewards period_type='guild-monthly').

import { jsonResponse, errorResponse, handleOptions } from "../_shared/cors.ts";
import { getDb } from "../_shared/db.ts";
import { callBestEffortRpc } from "../_shared/rpc_health.ts";
import { isValidUUID } from "../_shared/validation.ts";
import { stripBackup } from "../_shared/profile.ts";
import { resolveTenant } from "../_shared/tenant.ts";
import { TOP_CONTRIBUTORS } from "../_shared/guild_policy.ts";

const TOP_N = 50;

Deno.serve(async (req: Request) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;
  if (req.method !== "GET") return errorResponse(405, "method_not_allowed");

  const url = new URL(req.url);
  const deviceIdRaw = url.searchParams.get("deviceId");
  if (deviceIdRaw && !isValidUUID(deviceIdRaw)) {
    return errorResponse(400, "invalid_device_id");
  }
  // UUID lowercase 정규화 — leaderboard와 동일 (#94 교훈).
  const deviceId = deviceIdRaw ? deviceIdRaw.toLowerCase() : null;

  const db = getDb();

  // 직전 달 길드 정산 lazy trigger — 개인 leaderboard의 finalize 패턴과 동일(테넌트별 정산은 함수 내부).
  // 실패해도 조회는 계속하되 rpc_failures에 남긴다 (#243).
  await callBestEffortRpc(db, "finalize_monthly_guild_rp_if_needed");

  // 호출자 테넌트 — 미등록/익명은 기본(public) 길드 보드. 클라는 tenant를 주장 못 한다(§2-1).
  let tenant = "public";
  if (deviceId) {
    const t = await resolveTenant(db, deviceId);
    if (t) tenant = t;
  }

  const { data: top, error: topErr } = await db
    .from("guild_monthly_scores")
    .select("guild_id, name, score, member_count, rank, logo")
    .eq("tenant_id", tenant)
    .order("rank", { ascending: true })
    .limit(TOP_N);
  if (topErr) {
    console.error("guild leaderboard fetch failed", topErr);
    return errorResponse(500, "fetch_failed");
  }

  // 길드별 상위 기여자 — 점수에 실제로 반영되는 rn <= TOP_CONTRIBUTORS 멤버.
  // 길드마다 따로 조회하면 N+1이 되므로 한 번에 긁어와 JS에서 그룹핑한다.
  //
  // profile_json은 통째로 실으면 안 된다 — 백업 페이로드까지 들어 있어 50길드×5명이면
  // 응답이 수백 KB로 불어난다. 렌더에 필요한 건 아바타 펫(kind/variant)뿐이라 그것만 뽑는다.
  const topMembersByGuild = new Map<string, unknown[]>();
  const guildIds = (top ?? []).map((g) => g.guild_id);
  if (guildIds.length > 0) {
    const { data: contributors } = await db
      .from("guild_member_monthly_vp")
      .select("guild_id, device_id, monthly_vp, rn")
      .in("guild_id", guildIds)
      .lte("rn", TOP_CONTRIBUTORS)
      .order("rn", { ascending: true });

    const deviceIds = [...new Set((contributors ?? []).map((c) => c.device_id))];
    const profiles = new Map<string, { nickname: string | null; profile: unknown }>();
    if (deviceIds.length > 0) {
      // 뷰(guild_member_monthly_vp)라 PostgREST가 users 관계를 추론하지 못한다 — 별도 조회 후 조인.
      const { data: users } = await db
        .from("users")
        .select("device_id, nickname, profile_json")
        .in("device_id", deviceIds);
      for (const u of users ?? []) {
        profiles.set(u.device_id, { nickname: u.nickname, profile: u.profile_json });
      }
    }
    for (const c of contributors ?? []) {
      const u = profiles.get(c.device_id);
      const card = (u?.profile as { card?: { avatar?: { kind?: string; variant?: number } } } | null)
        ?.card?.avatar;
      const list = topMembersByGuild.get(c.guild_id) ?? [];
      list.push({
        nickname: u?.nickname ?? "(탈퇴)",
        petKind: typeof card?.kind === "string" ? card.kind : null,
        petVariant: typeof card?.variant === "number" ? card.variant : 0,
        vp: Number(c.monthly_vp),
      });
      topMembersByGuild.set(c.guild_id, list);
    }
  }

  const { count: totalCount } = await db
    .from("guild_monthly_scores")
    .select("guild_id", { count: "exact", head: true })
    .eq("tenant_id", tenant);

  // 내 길드 — deviceId가 멤버일 때만.
  let myGuild: unknown = null;
  if (deviceId) {
    const { data: membership } = await db
      .from("guild_members")
      .select("guild_id")
      .eq("device_id", deviceId)
      .maybeSingle();
    if (membership) {
      const { data: mine } = await db
        .from("guild_monthly_scores")
        .select("guild_id, name, score, member_count, rank, logo")
        .eq("guild_id", membership.guild_id)
        .maybeSingle();
      if (mine) {
        myGuild = {
          guildId: mine.guild_id,
          name: mine.name,
          score: Number(mine.score),
          memberCount: mine.member_count,
          rank: mine.rank,
          logo: mine.logo ?? null,
        };
      }
    }
  }

  // 직전 달 길드 시상대 — 가장 최근 finalized period의 Top3 (개인 previousMonth 패턴).
  let previousMonth: unknown = null;
  {
    const { data: prevWinners } = await db
      .from("guild_monthly_winners")
      .select("period, rank, guild_id, name_snapshot, score, member_count, leader_nickname_snapshot, leader_profile_json_snapshot")
      .eq("tenant_id", tenant)
      .order("period", { ascending: false })
      .order("rank", { ascending: true })
      .limit(3);
    if (prevWinners && prevWinners.length > 0) {
      const latestPeriod = prevWinners[0].period;
      const filtered = prevWinners.filter((w) => w.period === latestPeriod);
      // 요청자의 길드가 시상대에 있으면 그 rank — 클라 하이라이트용.
      let myGuildRank: number | null = null;
      if (deviceId) {
        const { data: membership } = await db
          .from("guild_members")
          .select("guild_id")
          .eq("device_id", deviceId)
          .maybeSingle();
        if (membership) {
          const mine = filtered.find((w) => w.guild_id === membership.guild_id);
          myGuildRank = mine ? mine.rank : null;
        }
      }
      previousMonth = {
        period: latestPeriod,
        myGuildRank,
        entries: filtered.map((w) => ({
          rank: w.rank,
          name: w.name_snapshot,
          score: Number(w.score),
          memberCount: w.member_count,
          leaderNickname: w.leader_nickname_snapshot,
          leaderProfileJson: stripBackup(w.leader_profile_json_snapshot),
        })),
      };
    }
  }

  // 다음 달 1일 00:00 KST — 개인 leaderboard와 동일한 리셋 표기.
  const now = new Date();
  const seoulOffsetMs = 9 * 60 * 60 * 1000;
  const seoulNow = new Date(now.getTime() + seoulOffsetMs);
  const nextResetSeoul = new Date(Date.UTC(seoulNow.getUTCFullYear(), seoulNow.getUTCMonth() + 1, 1));
  const nextResetUtc = new Date(nextResetSeoul.getTime() - seoulOffsetMs);

  return jsonResponse({
    entries: (top ?? []).map((g) => ({
      rank: g.rank,
      guildId: g.guild_id,
      name: g.name,
      score: Number(g.score),
      memberCount: g.member_count,
      logo: g.logo ?? null,
      topMembers: topMembersByGuild.get(g.guild_id) ?? [],
    })),
    myGuild,
    total: totalCount ?? (top ?? []).length,
    period: "monthly",
    periodResetAt: nextResetUtc.toISOString(),
    previousMonth,
  });
});
