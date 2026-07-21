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
import { genericSkill, typeSharedSkill, collectionSharedSkill, type BattleType } from "./pvp_policy.ts";

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

Deno.test("레인보우 배틀 파리티 (이로치 버프 + 레인보우 크리 + variant4 스킬셋) — seed 9999999", () => {
  // A: 레인보우(variant 4) — 이로치 버프 + 크리 / B: 기본(variant 0). variant4는 generic+typeShared+
  // collectionShared까지 보유(Phase B) → 방어자별로 typeShared/오프타입 커버리지를 골라 데미지가 바뀐다.
  // 크리는 공격자가 레인보우일 때만 조건부 rng draw(비-레인보우 배틀 불변). Swift --arena-demo
  // PARITYRAINBOW 골든과 대조 — TS 스킬 선택/크리/variant 버프가 드리프트하면 여기서 잡힌다.
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
  assertEq("rounds", r.rounds, 27);
  assertEq("crit count", r.log.filter((e) => e.crit).length, 4);
  assertEq("dmg sequence", r.log.map((e) => e.damage),
    [17, 2, 11, 15, 2, 10, 11, 10, 19, 11, 11, 18, 11, 15, 25, 10, 23, 25, 15, 23, 10, 23, 24, 11, 25, 11, 23]);
});

Deno.test("커버리지 배틀 파리티 (variant2 오프타입 collectionShared 선택) — seed 2468013", () => {
  // A: variant2 mainframe(beast) 3마리 — 자기타입 beast는 machine에 약(×0.5)이라 선택 AI가 오프타입
  //    collectionShared(mainframe_overload=machine)를 고른다. B: variant0 machine 3마리.
  // Swift --arena-demo PARITYCOVERAGE 골든과 대조 — 오프타입 스킬 카탈로그·선택 AI가 드리프트하면
  // A가 고르는 무브(=aMoves)나 데미지가 어긋나 여기서 잡힌다.
  const snap = (kind: string, v: number) => ({ kind, variant: v, enhanceLevel: 5, progressUnits: 2 });
  const teamA: BattleTeam = [snap("fox", 2), snap("wolf", 2), snap("bear", 2)];
  const teamB: BattleTeam = [snap("scrapBot", 0), snap("antennaBot", 0), snap("pixelBot", 0)];
  const r = simulate(teamA, teamB, 2468013n);
  assertEq("winner", r.winner, "b");
  assertEq("rounds", r.rounds, 26);
  // A는 오프타입 커버리지만 사용(자기타입 typeShared는 machine 상대로 손해라 선택 안 함).
  const aMoves = [...new Set(r.log.filter((e) => e.attacker === "a").map((e) => e.move))].sort();
  assertEq("A moves", aMoves, ["mainframe_overload"]);
  assertEq("dmg sequence", r.log.map((e) => e.damage),
    [9, 21, 9, 9, 22, 9, 22, 9, 22, 9, 9, 9, 22, 9, 9, 21, 9, 23, 9, 9, 23, 9, 7, 3, 7, 26]);
});

// 스킬 카탈로그 전량 파리티 — 배틀 골든은 mainframe 경로 하나만 운동시켜 collectionShared type 18/19가
// 무커버다. 이 덤프로 6 generic·6 typeShared·19 collectionShared의 id/type/power를 통째로 잠근다.
// 골든은 Swift --arena-demo PARITYSKILLCAT 라인에서 캡처. 한 엔트리라도 Swift↔TS 드리프트하면 여기서 잡힌다.
const GOLD_SKILL_CATALOG =
  "PARITYSKILLCAT arcane:g=hotfix/arcane/8,ts=context_overflow/arcane/11 beast:g=hotfix/beast/8,ts=mem_leak/beast/11 chaos:g=hotfix/chaos/8,ts=friday_deploy/chaos/11 machine:g=hotfix/machine/8,ts=regression_sweep/machine/11 mascot:g=hotfix/mascot/8,ts=onboarding/mascot/11 warrior:g=hotfix/warrior/8,ts=force_push/warrior/11 ciRunners:cs=pipeline_stall/arcane/12 deprecated:cs=deprecated_strike/warrior/12 dns:cs=dns_propagation/arcane/12 emotionalSupport:cs=emotional_support/mascot/12 fridayDeploy:cs=friday_5pm/warrior/12 happyPath:cs=happy_path/beast/12 helloWorld:cs=hello_world/arcane/12 mainframe:cs=mainframe_overload/machine/12 noVerify:cs=no_verify/chaos/12 nodeModules:cs=node_modules_summon/arcane/12 npmInstall:cs=dependency_hell/chaos/12 onCall:cs=oncall_page/beast/12 oomKilled:cs=oom_kill/machine/12 rustEvangelists:cs=rewrite_in_rust/machine/12 tenXEngineer:cs=tenx_refactor/beast/12 todoSince2019:cs=tech_debt_invoice/warrior/12 tokenBurners:cs=token_burn/chaos/12 vibeCoders:cs=vibe_coding/chaos/12 wontfix:cs=wontfix_close/mascot/12";

Deno.test("스킬 카탈로그 파리티 — generic·typeShared·collectionShared(19 type) 전량 Swift와 대조", () => {
  const TYPES: BattleType[] = ["beast", "warrior", "chaos", "arcane", "machine", "mascot"];
  const COLLECTIONS = [
    "mainframe", "emotionalSupport", "npmInstall", "nodeModules", "dns", "deprecated",
    "vibeCoders", "tenXEngineer", "onCall", "rustEvangelists", "noVerify", "wontfix",
    "oomKilled", "fridayDeploy", "tokenBurners", "todoSince2019", "ciRunners", "happyPath", "helloWorld",
  ];
  const parts: string[] = [];
  for (const t of [...TYPES].sort()) {   // JS 기본 정렬 = Swift rawValue 정렬(전부 ASCII)과 일치
    const g = genericSkill(t), ts = typeSharedSkill(t);
    parts.push(`${t}:g=${g.id}/${g.type}/${g.power},ts=${ts.id}/${ts.type}/${ts.power}`);
  }
  for (const c of [...COLLECTIONS].sort()) {
    const cs = collectionSharedSkill(c);
    parts.push(`${c}:cs=${cs.id}/${cs.type}/${cs.power}`);
  }
  assertEq("skill catalog", "PARITYSKILLCAT " + parts.join(" "), GOLD_SKILL_CATALOG);
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
