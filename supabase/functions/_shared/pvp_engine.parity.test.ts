// 서버 엔진 ↔ Swift 파리티 회귀 테스트.
//
// 골든 값은 Swift `swift run ClaudeUsage --arena-demo` 의 결정적 출력에서 고정 캡처. TS 포트
// (battle_engine/enhance_engine/pvp_policy)가 Swift와 비트 단위로 일치함을 잠근다. 엔진 로직을
// 고치면 양쪽(Swift·TS)이 함께 바뀌어야 이 테스트가 통과한다 — 한쪽만 드리프트하면 잡힌다.
//
// 실행:  deno test supabase/functions/_shared/pvp_engine.parity.test.ts
// (외부 의존 없음 — std/assert 미사용, 자체 assert.)

import { SeededRNG, roll, apply, baseCost, expectedVP, safeOdds, safeCost, cost, canSafeEnhance, rollSafe } from "./enhance_engine.ts";
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
// 스킬 전환(Phase A) 후 재캡처 — 스킬 상성 ×2.0/×0.5 + 자속 STAB ×1.5, generic "hotfix"(power 8).
const GOLD_BATTLE_DMG = [33, 4, 34, 32, 4, 33, 4, 31, 11, 18, 11, 18, 11, 18, 11, 17];
const GOLD_BATTLE_WINNER = "a";
const GOLD_BATTLE_ROUNDS = 16;

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

Deno.test("5v5 배틀 파리티 (누진 시너지 4/5 티어 + 타입 tie-break) — seed 5555555", () => {
  // A: warrior 5동족(컬렉션5=+0.26·타입5=+0.15 atk) / B: 타입 동수 2+2+1(tie는 팀 순서 first=beast).
  // 골든은 Swift --arena-demo 의 PARITY5V5 라인에서 캡처. TS teamSynergyBonus 의 tie-break·4/5 티어가
  // Swift 와 드리프트하면 데미지 시퀀스가 어긋나 여기서 잡힌다.
  const snap = (kind: string) => ({ kind, variant: 0, enhanceLevel: 5, progressUnits: 2 });
  const teamA: BattleTeam = [snap("warrior"), snap("lancer"), snap("monk"), snap("archer"), snap("pawn")];
  const teamB: BattleTeam = [snap("fox"), snap("wolf"), snap("scrapBot"), snap("antennaBot"), snap("warrior")];
  const r = simulate(teamA, teamB, 5555555n);
  assertEq("winner", r.winner, "a");
  assertEq("rounds", r.rounds, 19);
  assertEq("dmg sequence", r.log.map((e) => e.damage),
    [39, 5, 40, 40, 5, 40, 54, 57, 56, 60, 21, 12, 21, 12, 22, 13, 22, 12, 21]);
});

Deno.test("레인보우 배틀 파리티 (이로치 +18% 버프 + 레인보우 크리) — seed 9999999", () => {
  // A: 레인보우(variant 4) — 이로치 버프 + 크리 / B: 기본(variant 0). 크리는 공격자가 레인보우일 때만
  // 조건부 rng draw(비-레인보우 배틀 불변). Swift --arena-demo PARITYRAINBOW 골든과 대조 — TS 크리·
  // variant 버프가 Swift와 드리프트하면 데미지 시퀀스/크리 수가 어긋나 여기서 잡힌다.
  const teamA: BattleTeam = [
    { kind: "fox", variant: 4, enhanceLevel: 5, progressUnits: 2 },
    { kind: "wolf", variant: 4, enhanceLevel: 5, progressUnits: 2 },
    { kind: "bear", variant: 4, enhanceLevel: 5, progressUnits: 2 },
  ];
  const teamB: BattleTeam = [
    { kind: "scrapBot", variant: 0, enhanceLevel: 5, progressUnits: 2 },
    { kind: "antennaBot", variant: 0, enhanceLevel: 5, progressUnits: 2 },
    { kind: "warrior", variant: 0, enhanceLevel: 5, progressUnits: 2 },
  ];
  const r = simulate(teamA, teamB, 9999999n);
  assertEq("winner", r.winner, "b");
  assertEq("rounds", r.rounds, 32);
  assertEq("crit count", r.log.filter((e) => e.crit).length, 4);
  assertEq("dmg sequence", r.log.map((e) => e.damage),
    [11, 2, 8, 11, 2, 7, 7, 18, 7, 8, 8, 18, 7, 11, 19, 7, 7, 18, 7, 2, 8, 8, 24, 10, 24, 17, 23, 24, 11, 23, 10, 23]);
});

Deno.test("결정성 — 동일 (팀+시드) → 동일 로그", () => {
  const t: BattleTeam = [{ kind: "fox", variant: 0, enhanceLevel: 0, progressUnits: 0 }];
  const r1 = simulate(t, [{ kind: "warrior", variant: 0, enhanceLevel: 0, progressUnits: 0 }], 12345n);
  const r2 = simulate(t, [{ kind: "warrior", variant: 0, enhanceLevel: 0, progressUnits: 0 }], 12345n);
  assertEq("동일", r1, r2);
});

Deno.test("안전 강화 파리티 — 파괴→유지 + soft-pity + 할증 (Swift EnhanceEngineTests와 동일 값)", () => {
  const s0 = safeOdds(10, 0);
  if (s0[3] !== 0) throw new Error("안전 모드 파괴 0 아님");
  if (Math.abs(s0[0] - 0.22) > 1e-9) throw new Error(`s0[0]=${s0[0]}`);
  if (Math.abs(s0.reduce((a, b) => a + b, 0) - 1) > 1e-9) throw new Error("합≠1");
  if (Math.abs(safeOdds(10, 5)[0] - 0.32) > 1e-9) throw new Error("pity 5 불일치");
  if (Math.abs(safeOdds(10, 50)[0] - 0.42) > 1e-9) throw new Error("pity cap 불일치");
  if (canSafeEnhance(12)) throw new Error("+12 안전 가능하면 안 됨");
  if (!(safeCost(10, "common") > cost(10, "common"))) throw new Error("할증 아님");
  // rollSafe는 파괴를 안 냄.
  for (let i = 0; i < 2000; i++) {
    const rng = new SeededRNG(BigInt(i) * 2654435761n + 7n);
    if (rollSafe(14, 0, rng) === "destroy") throw new Error("안전 모드에서 파괴 발생");
  }
});

Deno.test("기대 VP — 파괴 리셋 반영(+15 ≈ 5.3M)", () => {
  const e15 = expectedVP(15);
  if (!(e15 > 5_000_000 && e15 < 5_600_000)) throw new Error(`expectedVP(15)=${e15} 범위 밖`);
  if (!(Math.abs(expectedVP(1) - 20) < 3)) throw new Error(`expectedVP(1)=${expectedVP(1)}`);
});
