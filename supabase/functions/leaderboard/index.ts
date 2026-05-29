// GET /leaderboard?deviceId=<uuid>
// 월간 랭킹 — KST 기준 1일 00:00 ~ 다음 달 1일 00:00 윈도우. monthly_leaderboard view 사용.
// deviceId 없으면 익명 조회 (myRank/myTotalCoins = null).

import { jsonResponse, errorResponse, handleOptions } from "../_shared/cors.ts";
import { getDb } from "../_shared/db.ts";
import { isValidUUID } from "../_shared/validation.ts";

const TOP_N = 100;

// =========================================================================
// SSOT: profile_json.backup 누출 방지.
// `BackupPayload` (ProfileState.swift) 는 본인 디바이스 복구 전용 페이로드이며
// 다른 사용자에게는 절대 노출되면 안 된다. 보드 응답으로 새는 일을 막는 단일
// 차단 지점이 이 함수다.
//
// 호출 의무:
//   - leaderboard entries[].profileJson         (line ~84)
//   - previousMonth.entries[].profileJson       (line ~108)
//   - profileJson 을 응답에 싣는 새 endpoint 가 추가되면 반드시 stripBackup 경유
//
// 새 백업 필드 추가 시 점검:
//   - ProfileState.BackupPayload 에 필드 추가
//   - Settings.applyBackup 머지 정책 정의
//   - 본 함수는 키 화이트리스트 방식이 아니라 "backup" 키 자체를 통째로 drop
//     하므로 백업 페이로드 내부 필드 추가는 본 함수 수정 불필요. 단, 백업이
//     아닌 새 민감 필드를 ProfileState 에 직접 추가한다면 키 화이트리스트
//     방식으로 전환 검토.
// =========================================================================
function stripBackup(pj: unknown): unknown {
  if (pj && typeof pj === "object" && pj !== null && "backup" in pj) {
    const { backup: _drop, ...rest } = pj as Record<string, unknown>;
    return rest;
  }
  return pj;
}

Deno.serve(async (req: Request) => {
  const preflight = handleOptions(req);
  if (preflight) return preflight;
  if (req.method !== "GET") return errorResponse(405, "method_not_allowed");

  const url = new URL(req.url);
  const deviceId = url.searchParams.get("deviceId");
  if (deviceId && !isValidUUID(deviceId)) {
    return errorResponse(400, "invalid_device_id");
  }

  const db = getDb();

  // 직전 달 finalize lazy trigger — 첫 호출자가 트리거. UNIQUE 제약으로 race-safe.
  // 호출당 1회 추가 쿼리이지만 EXISTS 가드로 이미 finalized면 즉시 return.
  await db.rpc("finalize_previous_month_if_needed");

  // Top N — 월간 보드 + profile_json
  const { data: top, error: topErr } = await db
    .from("monthly_leaderboard")
    .select("rank, nickname, github_login, monthly_coins, profile_json")
    .order("rank", { ascending: true })
    .limit(TOP_N);
  if (topErr) {
    console.error("leaderboard top fetch failed", topErr);
    return errorResponse(500, "fetch_failed");
  }

  // 총 참여자 (이번 달 monthly_coins > 0)
  const { count: totalCount } = await db
    .from("monthly_leaderboard")
    .select("device_id", { count: "exact", head: true });

  // 내 순위 — view에서 device_id로 조회
  let myRank: number | null = null;
  let myTotal: number | null = null;
  if (deviceId) {
    const { data: meRow } = await db
      .from("monthly_leaderboard")
      .select("rank, monthly_coins")
      .eq("device_id", deviceId)
      .maybeSingle();
    if (meRow) {
      myRank = meRow.rank;
      myTotal = meRow.monthly_coins;
    } else {
      // 보드에 없음 — 이번 달 적립 0이거나 banned. 본인 user row를 직접 조회해 0으로 표시.
      const { data: me } = await db
        .from("users")
        .select("status")
        .eq("device_id", deviceId)
        .maybeSingle();
      if (me && me.status === "active") {
        myTotal = 0;
      }
    }
  }

  const entries = (top ?? []).map((row) => ({
    rank: row.rank,
    nickname: row.nickname,
    totalCoins: row.monthly_coins,
    githubLogin: row.github_login,
    profileJson: stripBackup(row.profile_json),
  }));

  // 직전 달 명예의 전당 — 가장 최근 finalized period의 top 3.
  // 보드 상단 섹션 + reward 알림용. 클라이언트가 표시.
  const { data: prevWinners } = await db
    .from("monthly_winners")
    .select("period, rank, final_score, nickname_snapshot, profile_json_snapshot, reward_coins")
    .order("period", { ascending: false })
    .order("rank", { ascending: true })
    .limit(3);

  // period가 여러 개 섞여 있을 수 있어 최신 period로 필터.
  let previousMonth: unknown = null;
  if (prevWinners && prevWinners.length > 0) {
    const latestPeriod = prevWinners[0].period;
    const filtered = prevWinners.filter((w) => w.period === latestPeriod);
    previousMonth = {
      period: latestPeriod,
      entries: filtered.map((w) => ({
        rank: w.rank,
        nickname: w.nickname_snapshot,
        totalCoins: w.final_score,
        githubLogin: null,
        profileJson: stripBackup(w.profile_json_snapshot),
        rewardCoins: w.reward_coins,
      })),
    };
  }

  // 본인의 미수령 보상 — deviceId가 있을 때만 조회.
  let pendingReward: unknown = null;
  if (deviceId) {
    const { data: unclaimed } = await db
      .from("monthly_winners")
      .select("period, rank, reward_coins")
      .eq("device_id", deviceId)
      .is("reward_claimed_at", null)
      .order("period", { ascending: true })
      .limit(1)
      .maybeSingle();
    if (unclaimed) {
      pendingReward = {
        period: unclaimed.period,
        rank: unclaimed.rank,
        coins: unclaimed.reward_coins,
      };
    }
  }

  // 다음 달 1일 00:00 KST를 ISO 형태로 노출 — 클라이언트가 "리셋까지 N일" 표시에 사용.
  const now = new Date();
  const seoulOffsetMs = 9 * 60 * 60 * 1000;
  const seoulNow = new Date(now.getTime() + seoulOffsetMs);
  const nextResetSeoul = new Date(Date.UTC(seoulNow.getUTCFullYear(), seoulNow.getUTCMonth() + 1, 1));
  const nextResetUtc = new Date(nextResetSeoul.getTime() - seoulOffsetMs);

  return jsonResponse({
    entries,
    myRank,
    myTotalCoins: myTotal,
    total: totalCount ?? entries.length,
    period: "monthly",
    periodResetAt: nextResetUtc.toISOString(),
    previousMonth,
    pendingReward,
  });
});
