// 리더보드 조회 — `leaderboard` 엔드포인트와 `sync`가 공유한다.
//
// 원래 leaderboard/index.ts 안에 있던 조회·조립 로직을 그대로 옮긴 것이다(순수 이동).
//
// ⚠️ 백업 누출 방지: `profile_json.backup`은 본인 디바이스 복구 전용 페이로드라 다른 사용자에게
// 노출되면 안 된다. 응답에 profileJson을 싣는 지점은 반드시 `stripBackup()`을 거쳐야 한다.
// 이 모듈이 그 단일 차단 지점이며, 여기를 쓰는 모든 endpoint(leaderboard·sync)가 보호받는다.

import { getDb } from "./db.ts";
import { stripBackup } from "./profile.ts";

const TOP_N = 100;

/** 하위 조회가 실패했을 때. 호출부가 500으로 매핑한다. */
export class LeaderboardFetchError extends Error {}

/**
 * 월간 리더보드 + 내 순위/메달/대기중 보상. `tenant`는 호출부가 `resolveTenant`로 구해 넘긴다
 * (sync는 board/공지와 테넌트를 공유하므로 중복 조회를 피한다).
 */
export async function fetchLeaderboard(
  db: ReturnType<typeof getDb>,
  opts: { tenant: string; deviceId: string | null },
) {
  const { tenant, deviceId } = opts;

  // 직전 달 finalize lazy trigger — 첫 호출자가 트리거. UNIQUE 제약으로 race-safe.
  // 호출당 1회 추가 쿼리이지만 EXISTS 가드로 이미 finalized면 즉시 return.
  await db.rpc("finalize_previous_month_if_needed");
  // RP 정산 — 월간/주간 lazy trigger. 각 함수가 EXISTS 가드로 이미 정산됐으면 즉시 return.
  await db.rpc("finalize_monthly_rp_if_needed");
  await db.rpc("finalize_weekly_rp_if_needed");
  // Top N — 월간 보드(테넌트 파티션) + profile_json. device_id는 메달 매핑 internal용 — 응답엔 절대 미노출.
  const { data: top, error: topErr } = await db
    .from("monthly_leaderboard")
    .select("device_id, rank, nickname, github_login, monthly_coins, profile_json")
    .eq("tenant_id", tenant)
    .order("rank", { ascending: true })
    .limit(TOP_N);
  if (topErr) {
    console.error("leaderboard top fetch failed", topErr);
    throw new LeaderboardFetchError();
  }

  // 총 참여자 — 호출자 테넌트 내 active 사용자
  const { count: totalCount } = await db
    .from("monthly_leaderboard")
    .select("device_id", { count: "exact", head: true })
    .eq("tenant_id", tenant);

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

  // 누적 메달 집계 — top entries + 본인 device_id를 한 번에 조회 후 매핑.
  // device_id 자체는 응답 entries에 싣지 않는다 (UUID 신원 누출 방지).
  const medalDeviceIds = new Set<string>();
  for (const row of top ?? []) {
    if (row.device_id) medalDeviceIds.add(row.device_id);
  }
  if (deviceId) medalDeviceIds.add(deviceId);

  const zeroMedals = { gold: 0, silver: 0, bronze: 0 };
  const medalsByDevice = new Map<string, typeof zeroMedals>();
  if (medalDeviceIds.size > 0) {
    const { data: medalRows, error: medalErr } = await db
      .from("device_medals")
      .select("device_id, gold, silver, bronze")
      .in("device_id", [...medalDeviceIds]);
    if (medalErr) {
      console.error("leaderboard medals fetch failed", medalErr);
    } else {
      for (const m of medalRows ?? []) {
        medalsByDevice.set(m.device_id, {
          gold: Number(m.gold) || 0,
          silver: Number(m.silver) || 0,
          bronze: Number(m.bronze) || 0,
        });
      }
    }
  }

  const entries = (top ?? []).map((row) => ({
    rank: row.rank,
    nickname: row.nickname,
    totalCoins: row.monthly_coins,
    githubLogin: row.github_login,
    profileJson: stripBackup(row.profile_json),
    medals: medalsByDevice.get(row.device_id) ?? zeroMedals,
  }));

  // 본인 누적 메달 — 보드에 없어도(이번 달 0 VP) deviceId로 집계해 내려준다.
  const myMedals = deviceId ? (medalsByDevice.get(deviceId) ?? zeroMedals) : null;

  // 직전 달 명예의 전당 — 가장 최근 finalized period의 top 3.
  // 보드 상단 섹션 + reward 알림용. 클라이언트가 표시.
  // device_id/podium_message는 internal·표시용으로 select — device_id는 응답에 미노출.
  // 명예의 전당은 호출자 테넌트로 필터 — 타 테넌트의 직전 달 우승자 명단은 비노출(교차노출차단, §2-4-4).
  // (개인 메달 집계 device_medals는 필터 안 함 = 평생 업적 D11 — 별개 표면.)
  const { data: prevWinners } = await db
    .from("monthly_winners")
    .select("period, rank, final_score, nickname_snapshot, profile_json_snapshot, reward_coins, device_id, podium_message")
    .eq("tenant_id", tenant)
    .order("period", { ascending: false })
    .order("rank", { ascending: true })
    .limit(3);

  // period가 여러 개 섞여 있을 수 있어 최신 period로 필터.
  let previousMonth: unknown = null;
  if (prevWinners && prevWinners.length > 0) {
    const latestPeriod = prevWinners[0].period;
    const filtered = prevWinners.filter((w) => w.period === latestPeriod);
    // 요청자가 이 시상대의 우승자면 그 rank — 클라이언트가 "내 칸 한마디 등록" 여부 판정에 사용.
    const myWinner = deviceId ? filtered.find((w) => w.device_id === deviceId) : undefined;
    // 시상대 표기용 월간 RP 보상 — 같은 period의 rp_rewards 금액을 device_id로 매핑.
    // monthly_winners / rp_rewards 모두 DB 저장값(소문자 UUID)이라 케이스 불일치 없음.
    // RP 정산 전 period(기능 도입 이전 등)는 row가 없어 rewardRp: null.
    const { data: prevRp } = await db
      .from("rp_rewards")
      .select("device_id, rp_amount")
      .eq("period_type", "monthly")
      .eq("period", latestPeriod)
      .in("device_id", filtered.map((w) => w.device_id));
    const rpByDevice = new Map((prevRp ?? []).map((r) => [r.device_id, r.rp_amount]));
    previousMonth = {
      period: latestPeriod,
      myRank: myWinner ? myWinner.rank : null,
      entries: filtered.map((w) => ({
        rank: w.rank,
        nickname: w.nickname_snapshot,
        totalCoins: w.final_score,
        githubLogin: null,
        profileJson: stripBackup(w.profile_json_snapshot),
        rewardCoins: w.reward_coins,
        rewardRp: rpByDevice.get(w.device_id) ?? null,
        message: w.podium_message ?? null,
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

  // 본인의 미수령 RP 보상 (rp_rewards) — coins와 별도 원장. periodType으로 월간/주간 구분.
  // 첫 미수령 1건만 반환 (클라가 claim 후 다음 폴링에서 다음 건 수령).
  let pendingRpReward: unknown = null;
  if (deviceId) {
    const { data: rpUnclaimed } = await db
      .from("rp_rewards")
      .select("period, period_type, rank, rp_amount")
      .eq("device_id", deviceId)
      .is("claimed_at", null)
      .order("finalized_at", { ascending: true })
      .limit(1)
      .maybeSingle();
    if (rpUnclaimed) {
      pendingRpReward = {
        period: rpUnclaimed.period,
        periodType: rpUnclaimed.period_type,
        rank: rpUnclaimed.rank,
        rp: rpUnclaimed.rp_amount,
      };
    }
  }

  // 본인의 미수령 통합 보상(reward_grants) — RP·코인 공용 ops 지급 원장. currency로 클라가
  // 원장을 고른다. 가장 오래된 미수령 1건만 반환(클라가 claim 후 다음 폴링에서 다음 건 수령).
  let pendingGrant: unknown = null;
  if (deviceId) {
    const { data: grant } = await db
      .from("reward_grants")
      .select("currency, amount, grant_key")
      .eq("device_id", deviceId)
      .is("claimed_at", null)
      .order("created_at", { ascending: true })
      .limit(1)
      .maybeSingle();
    if (grant) {
      pendingGrant = {
        currency: grant.currency,
        amount: grant.amount,
        grantKey: grant.grant_key,
      };
    }
  }

  // 다음 달 1일 00:00 KST를 ISO 형태로 노출 — 클라이언트가 "리셋까지 N일" 표시에 사용.
  const now = new Date();
  const seoulOffsetMs = 9 * 60 * 60 * 1000;
  const seoulNow = new Date(now.getTime() + seoulOffsetMs);
  const nextResetSeoul = new Date(Date.UTC(seoulNow.getUTCFullYear(), seoulNow.getUTCMonth() + 1, 1));
  const nextResetUtc = new Date(nextResetSeoul.getTime() - seoulOffsetMs);

  // 재인증 요구 — 랭킹 화면을 여는 즉시 배너가 뜨도록 leaderboard에도 싣는다.
  // sync(최대 10분 주기)에만 실었더니 창을 열어도 한동안 안내가 안 나왔고, 유예 중에는
  // 소속이 게이트 테넌트라 헤더의 '사내 인증' 버튼도 숨겨져 진입로가 아예 없었다.
  let reverifyDueAt: string | null = null;
  if (deviceId) {
    const { data: caller } = await db
      .from("users")
      .select("tenant_reverify_due_at")
      .eq("device_id", deviceId.toLowerCase())
      .maybeSingle();
    reverifyDueAt = (caller?.tenant_reverify_due_at as string | null) ?? null;
  }

  return {
    entries,
    myRank,
    myTotalCoins: myTotal,
    myMedals,
    total: totalCount ?? entries.length,
    period: "monthly",
    periodResetAt: nextResetUtc.toISOString(),
    previousMonth,
    pendingReward,
    pendingRpReward,
    pendingGrant,   // 통합 ops 보상(RP·코인 공용) — 구클라는 미인식 필드라 무시
    tenant,   // 클라 배지용 — 호출자 현재 테넌트(익명/미등록은 "public")
    reverifyDueAt,   // 소속 재인증 기한. null이면 요구 없음
  };
}
