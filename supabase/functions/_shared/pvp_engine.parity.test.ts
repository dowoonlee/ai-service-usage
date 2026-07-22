// 서버 엔진 ↔ Swift 파리티 회귀 테스트.
//
// 골든 값은 Swift `swift run ClaudeUsage --arena-demo` 의 결정적 출력에서 고정 캡처. TS 포트
// (battle_engine/enhance_engine/pvp_policy)가 Swift와 비트 단위로 일치함을 잠근다. 엔진 로직을
// 고치면 양쪽(Swift·TS)이 함께 바뀌어야 이 테스트가 통과한다 — 한쪽만 드리프트하면 잡힌다.
//
// 실행:  deno test supabase/functions/_shared/pvp_engine.parity.test.ts
// (외부 의존 없음 — std/assert 미사용, 자체 assert.)

import { SeededRNG, roll, apply, baseCost, expectedVP, safeOdds, safeCost, cost, canSafeEnhance, rollSafe } from "./enhance_engine.ts";
import { simulate, BattleTeam, BattleResult } from "./battle_engine.ts";
import { genericSkill, typeSharedSkill, collectionSharedSkill, uniqueSkill, ultimateSkill, skillsFor, type BattleType, EFFECTS, ULT_EFFECT } from "./pvp_policy.ts";
import { UNIQUE_SKILL } from "./pet_meta_gen.ts";

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
// Phase C 재캡처 — HP ×1.5 스케일(TTK↑)로 라운드/데미지 시퀀스 변동. 스킬 상성 ×2.0/×0.5 + STAB ×1.5.
const GOLD_BATTLE_DMG = [33, 4, 34, 4, 34, 33, 4, 31, 4, 31, 32, 17, 11, 18, 10, 11, 18, 18, 10, 11, 17, 11, 18];
const GOLD_BATTLE_WINNER = "a";
const GOLD_BATTLE_ROUNDS = 23;

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
  assertEq("rounds", r.rounds, 25);
  assertEq("dmg sequence", r.log.map((e) => e.damage),
    [39, 5, 40, 40, 42, 5, 39, 57, 55, 60, 59, 21, 12, 21, 12, 22, 12, 21, 12, 22, 21, 1, 20, 12, 21]);
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
  // E2 재캡처 — variant4 A측 typeShared(mem_leak) rider draw가 RNG 스트림에 추가됨.
  const r = simulate(teamA, teamB, 9999999n);
  assertEq("winner", r.winner, "b");
  assertEq("rounds", r.rounds, 39);
  assertEq("crit count", r.log.filter((e) => e.crit).length, 6);
  assertEq("dmg sequence", r.log.map((e) => e.damage),
    [17, 2, 11, 15, 2, 10, 11, 18, 10, 17, 11, 18, 11, 15, 19, 10, 10, 18, 10, 23, 25, 25, 10, 25, 11, 24, 11, 25, 15, 23, 23, 24, 24, 2, 24, 11, 23, 11, 23]);
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
  assertEq("rounds", r.rounds, 40);
  // A는 오프타입 커버리지만 사용(자기타입 typeShared는 machine 상대로 손해라 선택 안 함).
  const aMoves = [...new Set(r.log.filter((e) => e.attacker === "a").map((e) => e.move))].sort();
  assertEq("A moves", aMoves, ["mainframe_overload"]);
  assertEq("dmg sequence", r.log.map((e) => e.damage),
    [9, 21, 9, 9, 22, 9, 22, 9, 9, 23, 9, 22, 9, 2, 9, 8, 22, 9, 9, 22, 9, 9, 22, 9, 21, 9, 8, 21, 9, 21, 9, 9, 2, 9, 22, 9, 7, 25, 8, 27]);
});

// 스킬 카탈로그 전량 파리티 — 배틀 골든은 mainframe 경로 하나만 운동시켜 collectionShared type 18/19가
// 무커버다. 이 덤프로 6 generic·6 typeShared·19 collectionShared의 id/type/power를 통째로 잠근다.
// 골든은 Swift --arena-demo PARITYSKILLCAT 라인에서 캡처. 한 엔트리라도 Swift↔TS 드리프트하면 여기서 잡힌다.
const GOLD_SKILL_CATALOG =
  "PARITYSKILLCAT arcane:g=hotfix/arcane/8,ts=context_overflow/arcane/11,ult=context_window_exceeded/arcane/24 beast:g=hotfix/beast/8,ts=mem_leak/beast/11,ult=kernel_panic/beast/24 chaos:g=hotfix/chaos/8,ts=friday_deploy/chaos/11,ult=total_outage/chaos/24 machine:g=hotfix/machine/8,ts=regression_sweep/machine/11,ult=blue_screen/machine/24 mascot:g=hotfix/mascot/8,ts=onboarding/mascot/11,ult=full_rollback/mascot/24 warrior:g=hotfix/warrior/8,ts=force_push/warrior/11,ult=rm_rf/warrior/24 ciRunners:cs=pipeline_stall/arcane/12 deprecated:cs=deprecated_strike/warrior/12 dns:cs=dns_propagation/arcane/12 emotionalSupport:cs=emotional_support/mascot/12 fridayDeploy:cs=friday_5pm/warrior/12 happyPath:cs=happy_path/beast/12 helloWorld:cs=hello_world/arcane/12 mainframe:cs=mainframe_overload/machine/12 noVerify:cs=no_verify/chaos/12 nodeModules:cs=node_modules_summon/arcane/12 npmInstall:cs=dependency_hell/chaos/12 onCall:cs=oncall_page/beast/12 oomKilled:cs=oom_kill/machine/12 rustEvangelists:cs=rewrite_in_rust/machine/12 tenXEngineer:cs=tenx_refactor/beast/12 todoSince2019:cs=tech_debt_invoice/warrior/12 tokenBurners:cs=token_burn/chaos/12 vibeCoders:cs=vibe_coding/chaos/12 wontfix:cs=wontfix_close/mascot/12 archer:u=remote_exec/warrior/14 bigDemon:u=prod_outage/chaos/14 clownCaptain:u=clown_deploy/warrior/14 dinoDragon:u=dino_stack/beast/14 fairy:u=pixie_patch/arcane/14 geralt:u=prompt_injection/warrior/14 ghost:u=zombie_process/chaos/14 gordon:u=crunch_mode/warrior/14 heroKnight:u=full_refactor/warrior/14 huntress:u=pinpoint_debug/warrior/14 kingHuman:u=legacy_monarch/arcane/14 knightF:u=blue_green/warrior/14 knightM:u=zero_downtime/warrior/14 lancer:u=zero_day/warrior/14 maskDude:u=anon_commit/warrior/14 medievalKing:u=feudal_arch/warrior/14 monk:u=zen_mode/warrior/14 mrMochi:u=infinite_scroll/mascot/14 ninjaFrog:u=stealth_deploy/warrior/14 ogre:u=monolith/chaos/14 orc:u=brute_merge/warrior/14 pawn:u=merge_conflict/warrior/14 pirateCaptain:u=code_plunder/warrior/14 plant:u=dependency_tree/arcane/14 princessSera:u=graceful_shutdown/mascot/14 pterodactyl:u=race_condition/beast/14 roboRetro:u=quantization/machine/14 skeletonLord:u=dead_code/chaos/14 skull:u=segfault/chaos/14 tRex:u=extinction_event/beast/14 visorBot:u=gradient_explosion/machine/14 warrior:u=fullstack_smash/warrior/14 whale:u=docker_whale/warrior/14 wizardM:u=hallucination/arcane/14";

Deno.test("스킬 카탈로그 파리티 — generic·typeShared·collectionShared(19)·unique(34 type) 전량 Swift와 대조", () => {
  const TYPES: BattleType[] = ["beast", "warrior", "chaos", "arcane", "machine", "mascot"];
  const COLLECTIONS = [
    "mainframe", "emotionalSupport", "npmInstall", "nodeModules", "dns", "deprecated",
    "vibeCoders", "tenXEngineer", "onCall", "rustEvangelists", "noVerify", "wontfix",
    "oomKilled", "fridayDeploy", "tokenBurners", "todoSince2019", "ciRunners", "happyPath", "helloWorld",
  ];
  const parts: string[] = [];
  for (const t of [...TYPES].sort()) {   // JS 기본 정렬 = Swift rawValue 정렬(전부 ASCII)과 일치
    const g = genericSkill(t), ts = typeSharedSkill(t), ult = ultimateSkill(t);
    parts.push(`${t}:g=${g.id}/${g.type}/${g.power},ts=${ts.id}/${ts.type}/${ts.power},ult=${ult.id}/${ult.type}/${ult.power}`);
  }
  for (const c of [...COLLECTIONS].sort()) {
    const cs = collectionSharedSkill(c);
    parts.push(`${c}:cs=${cs.id}/${cs.type}/${cs.power}`);
  }
  // unique 34 — pet_meta_gen(Swift uniqueTable에서 gen)에서 재구성. 골든이 stale gen(재생성 누락)을 잡는다.
  for (const k of Object.keys(UNIQUE_SKILL).sort()) {
    const u = uniqueSkill(k)!;
    parts.push(`${k}:u=${u.id}/${u.type}/${u.power}`);
  }
  assertEq("skill catalog", "PARITYSKILLCAT " + parts.join(" "), GOLD_SKILL_CATALOG);
});

Deno.test("고유기 배틀 파리티 (variant3 Epic+ per-kind unique 선택) — seed 1357902", () => {
  // 양측 mythic 전사 variant3(동급·동타입 미러) — warrior vs warrior 중립이라 자기타입 고파워 고유기(21)가
  // typeShared(16.5)를 이겨 채택. 선봉 교체로 warrior/monk/lancer 각자 고유기가 등장(per-kind 분기).
  const snap = (kind: string) => ({ kind, variant: 3, enhanceLevel: 5, progressUnits: 2 });
  const teamA: BattleTeam = [snap("warrior"), snap("lancer"), snap("monk")];
  const teamB: BattleTeam = [snap("archer"), snap("pawn"), snap("warrior")];
  // E2 재캡처 — warrior unique가 tech_debt rider를 상속(타입 특성)해 draw·grant가 스트림에 추가됨.
  // atk 디버프가 오가며 TTK가 늘어 42→47라운드.
  const r = simulate(teamA, teamB, 1357902n);
  assertEq("winner", r.winner, "b");
  assertEq("rounds", r.rounds, 47);
  const aMoves = [...new Set(r.log.filter((e) => e.attacker === "a").map((e) => e.move))].sort();
  const bMoves = [...new Set(r.log.filter((e) => e.attacker === "b").map((e) => e.move))].sort();
  assertEq("A moves(고유기)", aMoves, ["fullstack_smash", "zen_mode", "zero_day"]);
  assertEq("B moves(고유기)", bMoves, ["fullstack_smash", "merge_conflict", "remote_exec"]);
  assertEq("dmg sequence", r.log.map((e) => e.damage),
    [29, 22, 26, 22, 27, 23, 26, 22, 22, 22, 21, 27, 27, 21, 26, 27, 27, 28, 23, 29, 22, 22, 3, 22, 28, 22, 21, 23, 23, 22, 3, 27, 28, 2, 23, 28, 28, 28, 27, 23, 29, 25, 26, 37, 29, 38, 41]);
});

Deno.test("저레어 variant3 게이팅 — Common 펫은 고유기 없이 3슬롯(Swift testVariant3UniqueSlotGating 대칭)", () => {
  // fox = common → variant3에서도 generic+typeShared+collectionShared 3슬롯(고유기 미추가).
  // skillsFor의 `if (u)` null 가드가 빠지면 여기서 length가 4가 되거나 selectSkill이 크래시.
  assertEq("fox v3 slots", skillsFor("fox", 3).length, 3);
  assertEq("fox unique 없음", uniqueSkill("fox"), null);
  // Epic+는 4슬롯(warrior = mythic). 궁극기는 정규 슬롯이 아니라 별도(충전 발동)라 skillsFor에 안 들어감.
  assertEq("warrior v3 slots", skillsFor("warrior", 3).length, 4);
  assertEq("warrior v4 slots(궁극기 제외)", skillsFor("warrior", 4).length, 4);
});

Deno.test("궁극기 배틀 파리티 (variant4 팀 게이지 N=10 발동) — seed 8642097", () => {
  // 레인보우(variant4) 혼합 미러 — 게이지(행동 +1 · 피격 +1 · 기절 시 승계)가 ULT_CHARGE_COST=10에
  // 도달하면 궁극기 발동(정규 스킬 대체). 피격 충전·승계로 발동이 1→3회로 늘었다(rm_rf — warrior 타입).
  // Swift --arena-demo PARITYULT 골든과 대조 — 충전/승계/궁극기 데미지가 드리프트하면 여기서 잡힌다.
  const snap = (kind: string) => ({ kind, variant: 4, enhanceLevel: 5, progressUnits: 2 });
  const teamA: BattleTeam = [snap("fox"), snap("warrior"), snap("scrapBot")];
  const teamB: BattleTeam = [snap("wolf"), snap("lancer"), snap("antennaBot")];
  // E2 재캡처 — rm_rf 방어무시(def×0.3)로 궁극기 데미지 급증(124/151), 배틀 21→13라운드로 단축.
  const r = simulate(teamA, teamB, 8642097n);
  assertEq("winner", r.winner, "a");
  assertEq("rounds", r.rounds, 13);
  const ultIds = new Set(["kernel_panic", "rm_rf", "total_outage", "context_window_exceeded", "blue_screen", "full_rollback"]);
  const ults = r.log.filter((e) => ultIds.has(e.move));
  assertEq("궁극기 발동 수", ults.length, 2);
  assertEq("궁극기 종류", [...new Set(ults.map((e) => e.move))].sort(), ["rm_rf"]);
  assertEq("dmg sequence", r.log.map((e) => e.damage),
    [26, 24, 24, 25, 24, 25, 26, 80, 39, 124, 151, 70, 71]);
});

// 효과 이벤트 요약 — Swift ArenaDemo.battleSectionEffects의 PARITYFX 라인과 동일 집계.
function fxSummary(r: BattleResult) {
  const fx = r.effectEvents ?? [];
  const kinds: Record<string, number> = {};
  for (const e of fx) kinds[e.kind] = (kinds[e.kind] ?? 0) + 1;
  const kindsStr = Object.keys(kinds).sort().map((k) => `${k}:${kinds[k]}`).join(",");
  const ids = [...new Set(fx.map((e) => e.effectId).filter((x): x is string => x != null))].sort().join(",");
  const hp = fx.reduce((a, e) => a + (e.hpDelta ?? 0), 0);
  return { kindsStr, ids, hp };
}
const snapV4 = (kind: string) => ({ kind, variant: 4, enhanceLevel: 5, progressUnits: 2 });

Deno.test("효과 배틀 파리티 FX1 (동타입 5쌍 — rider·틱·스킵·스플래시·outage_stun) — seed 4812162", () => {
  // Swift --arena-demo PARITYFX1 골든과 대조 — DoT 틱/deadlock 스킵/kernel_panic 스플래시/실드/자힐이
  // 전부 운동된다. rounds(30) > log 길이(29) = 스킵 라운드는 공격 이벤트가 없다는 명세도 함께 잠금.
  const A: BattleTeam = ["fox", "bear", "wizardM", "bigDemon", "mrMochi"].map(snapV4);
  const B: BattleTeam = ["wolf", "tRex", "fairy", "skull", "princessSera"].map(snapV4);
  const r = simulate(A, B, 4812162n);
  const s = fxSummary(r);
  assertEq("winner", r.winner, "b");
  assertEq("rounds", r.rounds, 30);
  assertEq("fx kinds", s.kindsStr, "grant:6,heal:1,skip:1,splash:7,tick:4");
  assertEq("fx ids", s.ids, "deadlock,full_rollback,load_balancer,mem_leak,outage_stun");
  assertEq("fx hp", s.hp, -125);
  assertEq("dmg sequence", r.log.map((e) => e.damage),
    [3, 23, 28, 25, 26, 25, 27, 25, 41, 77, 26, 29, 31, 25, 29, 39, 45, 56, 20, 138, 33, 17, 21, 15, 22, 21, 26, 46, 116]);
});

Deno.test("효과 배틀 파리티 FX2 (혼합 상성 — 실드 refresh·자힐·bsod_lag·오프타입 rider 침묵) — seed 9624325", () => {
  const A: BattleTeam = ["bigDemon", "wizardM", "mrMochi"].map(snapV4);
  const B: BattleTeam = ["fox", "warrior", "scrapBot"].map(snapV4);
  const r = simulate(A, B, 9624325n);   // Swift: seed &* 2 &+ 1
  const s = fxSummary(r);
  assertEq("winner", r.winner, "a");
  assertEq("rounds", r.rounds, 32);
  assertEq("fx kinds", s.kindsStr, "grant:11,heal:3,tick:3");
  assertEq("fx ids", s.ids, "bsod_lag,full_rollback,load_balancer,mem_leak");
  assertEq("fx hp", s.hp, 95);
  assertEq("dmg sequence", r.log.map((e) => e.damage),
    [20, 3, 20, 27, 19, 19, 42, 21, 61, 260, 27, 43, 17, 38, 27, 18, 25, 18, 26, 94, 18, 42, 19, 25, 18, 15, 18, 18, 15, 17, 22, 45]);
});

// 효과 카탈로그 전량 파리티 — 효과 정의 14 + rider 배정 6 + 궁극기 특수효과 6을 통째로 잠근다.
// 배틀 골든이 못 건드리는 엔트리(tech_debt/legacy 수치 등)의 드리프트도 여기서 잡힌다.
const GOLD_FX_CATALOG =
  "PARITYFXCAT autoscaling=regen/0.06/3/- bsod_lag=statModSpd/0.6/2/- caching=statModSpd/1.25/3/- deadlock=controlChance/0.0/3/0.35 firewall=statModDef/1.3/3/- hot_reload=cleanse/0.0/0/- infinite_loop=dot/0.08/3/- legacy=statModSpd/0.75/3/- load_balancer=shield/0.2/3/- mem_leak=dot/0.05/3/- optimization=statModAtk/1.25/3/- outage_stun=controlFixed/0.0/1/- rate_limited=controlFixed/0.0/2/- tech_debt=statModAtk/0.8/3/- rider.arcane=deadlock/0.25/enemy rider.beast=mem_leak/0.3/enemy rider.chaos=infinite_loop/0.25/enemy rider.machine=legacy/0.3/enemy rider.mascot=load_balancer/1.0/self rider.warrior=tech_debt/0.3/enemy ult.blue_screen=grant:bsod_lag ult.context_window_exceeded=forceCrit ult.full_rollback=selfHeal:0.25 ult.kernel_panic=splash ult.rm_rf=defIgnore ult.total_outage=grant:outage_stun";

Deno.test("효과 카탈로그 파리티 — 효과 정의·rider 배정·궁극기 특수효과 전량 Swift와 대조", () => {
  // Swift Double description 재현: 정수값은 "1.0" 꼴, 그 외는 JS 기본 문자열과 일치.
  const num = (x: number) => Number.isInteger(x) ? x.toFixed(1) : String(x);
  const parts: string[] = [];
  for (const id of Object.keys(EFFECTS).sort()) {
    const d = EFFECTS[id].def;
    parts.push(`${id}=${d.kind}/${num(d.magnitude)}/${d.duration}/${d.chance == null ? "-" : num(d.chance)}`);
  }
  const TYPES: BattleType[] = ["arcane", "beast", "chaos", "machine", "mascot", "warrior"];   // rawValue 정렬
  for (const t of TYPES) {
    const r = typeSharedSkill(t).rider!;
    parts.push(`rider.${t}=${r.effectId}/${num(r.chance)}/${r.selfTarget ? "self" : "enemy"}`);
  }
  for (const id of Object.keys(ULT_EFFECT).sort()) {
    const u = ULT_EFFECT[id];
    const s = u.t === "grant" ? `grant:${u.effectId}` : u.t === "selfHeal" ? `selfHeal:${num(u.frac)}` : u.t;
    parts.push(`ult.${id}=${s}`);
  }
  assertEq("fx catalog", "PARITYFXCAT " + parts.join(" "), GOLD_FX_CATALOG);
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
