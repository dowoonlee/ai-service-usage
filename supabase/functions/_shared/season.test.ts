// 시즌 일일 보상 규칙 — 날짜 창 경계(KST)와 금액, 완주 1회.
//
//   deno test supabase/functions/_shared/season.test.ts
//
// 외부 의존 없음(사내망 JSR 차단) — policy.test.ts와 같은 자체 assert.
function assertEquals(got: unknown, exp: unknown, msg?: string) {
  const g = JSON.stringify(got), e = JSON.stringify(exp);
  if (g !== e) throw new Error(`${msg ? msg + " — " : ""}불일치\n  got: ${g}\n  exp: ${e}`);
}

import {
  ADVENT,
  adventCompleteKey,
  adventCompleteRewardFor,
  adventDailyPrefix,
  adventDailyRewardFor,
  kstDate,
  quizSeasonHint,
} from "./season.ts";

/** UTC 시각 → Date. KST = UTC+9. */
function utc(y: number, m: number, d: number, h = 0, min = 0): Date {
  return new Date(Date.UTC(y, m - 1, d, h, min));
}

Deno.test("kstDate — UTC 15:00이 KST 다음날 00:00", () => {
  assertEquals(kstDate(utc(2026, 11, 30, 14, 59)), { year: 2026, month: 11, day: 30 });
  assertEquals(kstDate(utc(2026, 11, 30, 15, 0)), { year: 2026, month: 12, day: 1 });
  assertEquals(kstDate(utc(2026, 12, 31, 15, 0)), { year: 2027, month: 1, day: 1 });
});

Deno.test("일일 보상 — 창 경계", () => {
  assertEquals(adventDailyRewardFor(utc(2026, 11, 30, 14, 59)), null, "11/30 KST");
  assertEquals(adventDailyRewardFor(utc(2026, 11, 30, 15, 0)), {
    grantKey: "advent-2026-12-01", amount: 50, reason: "advent 2026 day 1",
  }, "12/1 KST 00:00");
  assertEquals(adventDailyRewardFor(utc(2026, 12, 24, 3))?.grantKey, "advent-2026-12-24");
  assertEquals(adventDailyRewardFor(utc(2026, 12, 24, 3))?.amount, 300, "24일은 뽑기 1회분");
  assertEquals(adventDailyRewardFor(utc(2026, 12, 24, 15, 0)), null, "12/25 KST — 구간 밖");
  assertEquals(adventDailyRewardFor(utc(2027, 1, 10)), null);
});

Deno.test("일일 보상 — 같은 날 두 번은 같은 키(UNIQUE가 막는다)", () => {
  const a = adventDailyRewardFor(utc(2026, 12, 10, 1));
  const b = adventDailyRewardFor(utc(2026, 12, 10, 14));
  assertEquals(a?.grantKey, b?.grantKey);
  assertEquals(a?.grantKey, `${adventDailyPrefix(2026)}10`);
});

Deno.test("완주 보상 — 정확히 임계값에 도달한 submit에서만", () => {
  assertEquals(adventCompleteRewardFor(2026, ADVENT.completeThreshold - 1), null);
  assertEquals(adventCompleteRewardFor(2026, ADVENT.completeThreshold)?.grantKey, adventCompleteKey(2026));
  assertEquals(adventCompleteRewardFor(2026, ADVENT.completeThreshold)?.amount, 500);
  assertEquals(adventCompleteRewardFor(2026, ADVENT.completeThreshold + 1), null, "그 다음 submit은 null");
});

Deno.test("퀴즈 시즌 힌트 — 11/16~12/25만", () => {
  assertEquals(quizSeasonHint(utc(2026, 11, 14, 15, 0)), null, "11/15 KST");
  assertEquals(typeof quizSeasonHint(utc(2026, 11, 15, 15, 0)), "string", "11/16 KST 0시");
  assertEquals(typeof quizSeasonHint(utc(2026, 11, 20)), "string");
  assertEquals(typeof quizSeasonHint(utc(2026, 12, 10)), "string");
  assertEquals(quizSeasonHint(utc(2026, 12, 25, 15, 0)), null, "12/26 KST");
});
