// 서버 엔진 ↔ Swift 파리티 회귀 테스트.
//
// 골든 값은 Swift `swift run ClaudeUsage --arena-demo` 의 결정적 출력에서 고정 캡처. TS 포트
// (battle_engine/enhance_engine/pvp_policy)가 Swift와 비트 단위로 일치함을 잠근다. 엔진 로직을
// 고치면 양쪽(Swift·TS)이 함께 바뀌어야 이 테스트가 통과한다 — 한쪽만 드리프트하면 잡힌다.
//
// 실행:  deno test supabase/functions/_shared/pvp_engine.parity.test.ts
// (외부 의존 없음 — std/assert 미사용, 자체 assert.)

import { SeededRNG, roll, apply, baseCost, expectedVP } from "./enhance_engine.ts";
import { simulate, BattleTeam } from "./battle_engine.ts";

function assertEq(name: string, got: unknown, exp: unknown) {
  const g = JSON.stringify(got), e = JSON.stringify(exp);
  if (g !== e) throw new Error(`${name} 불일치\n  got: ${g}\n  exp: ${e}`);
}

// ── 골든 (Swift --arena-demo, 고정 시드) ──────────────────────────────────────
const GOLD_ENHANCE_OUTCOMES = [
  "stay", "destroy", "success", "success", "success", "stay", "success", "success",
  "stay", "stay", "success", "success", "stay", "downgrade", "success", "stay",
  "downgrade", "success",
];
const GOLD_ENHANCE_TOTAL_VP = 9295;
const GOLD_ENHANCE_FINAL = 7;
const GOLD_BATTLE_DMG = [31, 4, 32, 4, 32, 31, 4, 29, 4, 30, 9, 15, 9, 15, 9, 14, 9, 14, 9, 15];
const GOLD_BATTLE_WINNER = "a";
const GOLD_BATTLE_ROUNDS = 20;

Deno.test("강화 도박 파리티 — seed 20260716, +10 시작", () => {
  const rng = new SeededRNG(20260716n);
  let level = 10, spent = 0, attempts = 0;
  const outcomes: string[] = [];
  while (attempts < 18 && level < 15) {
    attempts++;
    spent += baseCost(level);           // ArenaDemo 는 Common 기본 비용 사용
    const outcome = roll(level, rng);
    level = apply(level, outcome);
    outcomes.push(outcome);
  }
  assertEq("outcomes", outcomes, GOLD_ENHANCE_OUTCOMES);
  assertEq("total VP", spent, GOLD_ENHANCE_TOTAL_VP);
  assertEq("final level", level, GOLD_ENHANCE_FINAL);
});

Deno.test("3v3 배틀 파리티 — seed 7251990", () => {
  const snap = (kind: string) => ({ kind, variant: 0, enhanceLevel: 8, progressUnits: 4 });
  const teamA: BattleTeam = [snap("baldPirate"), snap("fox"), snap("wolf")];
  const teamB: BattleTeam = [snap("scrapBot"), snap("antennaBot"), snap("bear")];
  const r = simulate(teamA, teamB, 7251990n);
  assertEq("winner", r.winner, GOLD_BATTLE_WINNER);
  assertEq("rounds", r.rounds, GOLD_BATTLE_ROUNDS);
  assertEq("dmg sequence", r.log.map((e) => e.damage), GOLD_BATTLE_DMG);
});

Deno.test("결정성 — 동일 (팀+시드) → 동일 로그", () => {
  const t: BattleTeam = [{ kind: "fox", variant: 0, enhanceLevel: 0, progressUnits: 0 }];
  const r1 = simulate(t, [{ kind: "warrior", variant: 0, enhanceLevel: 0, progressUnits: 0 }], 12345n);
  const r2 = simulate(t, [{ kind: "warrior", variant: 0, enhanceLevel: 0, progressUnits: 0 }], 12345n);
  assertEq("동일", r1, r2);
});

Deno.test("기대 VP — 파괴 리셋 반영(+15 ≈ 5.3M)", () => {
  const e15 = expectedVP(15);
  if (!(e15 > 5_000_000 && e15 < 5_600_000)) throw new Error(`expectedVP(15)=${e15} 범위 밖`);
  if (!(Math.abs(expectedVP(1) - 20) < 3)) throw new Error(`expectedVP(1)=${expectedVP(1)}`);
});
