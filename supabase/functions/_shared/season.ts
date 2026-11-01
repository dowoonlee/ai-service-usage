// 시즌 이벤트 — 서버 측 날짜 창과 일일 보상 규칙 (cf. docs/plans/seasonal-events.md §18~19).
//
// 클라이언트 `SeasonRegistry`(Swift)와 **같은 값**을 유지한다. 서버 시계·KST 기준이라 클라 시계를
// 돌려도 보상은 안 바뀐다. 보상 행은 `reward_grants`(UNIQUE(device_id, grant_key))에 넣고 클라가
// 기존 pendingGrant → claim-reward 경로로 수령한다 — 새 테이블·새 클레임 경로 없음.
//
// grant_key 규칙 (클라 `Settings.claimedGrants` 접두 필터와 합의):
//   일일:  advent-<year>-12-<DD>     (DD 두 자리, 1~24)
//   완주:  advent-<year>-complete    (일일 행이 completeThreshold개에 도달한 submit에서 함께 삽입)

const KST_OFFSET_MS = 9 * 3600 * 1000;

export interface KstDate {
  year: number;
  month: number; // 1~12
  day: number;   // 1~31
}

/** `now`를 KST 달력 날짜로. */
export function kstDate(now: Date): KstDate {
  const d = new Date(now.getTime() + KST_OFFSET_MS);
  return { year: d.getUTCFullYear(), month: d.getUTCMonth() + 1, day: d.getUTCDate() };
}

/** 두 자리 패딩. */
function pad2(n: number): string {
  return n < 10 ? `0${n}` : `${n}`;
}

export interface DailyRewardSpec {
  grantKey: string;
  amount: number;
  reason: string;
}

/** 12월 일일 보상 규칙. 클라 `SeasonRegistry.all[.xmas].rewardDays`(1...24)와 같아야 한다. */
export const ADVENT = {
  month: 12,
  firstDay: 1,
  lastDay: 24,
  dailyAmount: 50,
  lastDayAmount: 300,
  completeThreshold: 20,
  completeAmount: 500,
} as const;

/** 일일 보상 grant_key 접두 — 해당 연도 행 개수를 셀 때 LIKE 패턴으로 쓴다. */
export function adventDailyPrefix(year: number): string {
  return `advent-${year}-${pad2(ADVENT.month)}-`;
}

export function adventCompleteKey(year: number): string {
  return `advent-${year}-complete`;
}

/**
 * `now`(KST)가 보상 구간이면 그날의 일일 보상, 아니면 null.
 * submit이 accepted 처리된 뒤 호출 — "그날 AI를 썼다"는 submit 자체가 증명한다.
 */
export function adventDailyRewardFor(now: Date): DailyRewardSpec | null {
  const { year, month, day } = kstDate(now);
  if (month !== ADVENT.month || day < ADVENT.firstDay || day > ADVENT.lastDay) return null;
  const amount = day === ADVENT.lastDay ? ADVENT.lastDayAmount : ADVENT.dailyAmount;
  return {
    grantKey: `${adventDailyPrefix(year)}${pad2(day)}`,
    amount,
    reason: `advent ${year} day ${day}`,
  };
}

/**
 * 일일 행이 `receivedCount`개가 된 시점의 완주 보상. 정확히 임계값에 도달했을 때만 — 그 submit에서
 * 1회 삽입하고, 그 뒤 submit은 null(UNIQUE가 이중 삽입도 막지만 호출 자체를 줄인다).
 */
export function adventCompleteRewardFor(year: number, receivedCount: number): DailyRewardSpec | null {
  if (receivedCount !== ADVENT.completeThreshold) return null;
  return {
    grantKey: adventCompleteKey(year),
    amount: ADVENT.completeAmount,
    reason: `advent ${year} complete (${receivedCount}/${ADVENT.lastDay})`,
  };
}

/** 데일리 퀴즈 생성 프롬프트에 붙일 시즌 힌트. 시즌 밖이면 null. 릴리스 없이 서버만 바꾸는 항목. */
export function quizSeasonHint(now: Date): string | null {
  const { month, day } = kstDate(now);
  if (month === 12 && day <= 25) {
    return "지금은 12월입니다 — 연말 결산·올해의 AI·크리스마스 시즌 성격의 기사가 있으면 우선 고르세요(없으면 평소 기준).";
  }
  return null;
}
