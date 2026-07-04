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
import { isValidUUID } from "../_shared/validation.ts";
import { stripBackup } from "../_shared/profile.ts";

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

  // 직전 달 길드 정산 lazy trigger — 개인 leaderboard의 finalize 패턴과 동일.
  await db.rpc("finalize_monthly_guild_rp_if_needed");

  const { data: top, error: topErr } = await db
    .from("guild_monthly_scores")
    .select("guild_id, name, score, member_count, rank")
    .order("rank", { ascending: true })
    .limit(TOP_N);
  if (topErr) {
    console.error("guild leaderboard fetch failed", topErr);
    return errorResponse(500, "fetch_failed");
  }

  const { count: totalCount } = await db
    .from("guild_monthly_scores")
    .select("guild_id", { count: "exact", head: true });

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
        .select("guild_id, name, score, member_count, rank")
        .eq("guild_id", membership.guild_id)
        .maybeSingle();
      if (mine) {
        myGuild = {
          guildId: mine.guild_id,
          name: mine.name,
          score: Number(mine.score),
          memberCount: mine.member_count,
          rank: mine.rank,
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
    })),
    myGuild,
    total: totalCount ?? (top ?? []).length,
    period: "monthly",
    periodResetAt: nextResetUtc.toISOString(),
    previousMonth,
  });
});
