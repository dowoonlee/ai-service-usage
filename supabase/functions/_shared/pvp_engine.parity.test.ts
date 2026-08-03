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
import { genericSkill, typeSharedSkill, collectionSharedSkill, uniqueSkill, ultimateSkill, skillsFor, type BattleType, EFFECTS, ULT_EFFECT, TYPE_SHARED_RIDER } from "./pvp_policy.ts";
import { UNIQUE_SKILL, GENERIC_SKILL } from "./pet_meta_gen.ts";

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
  // E3 재캡처 — mainframe cs rider(legacy, enemy)가 추가돼 A측 variant2 스킬에도 rider draw가 붙음.
  const r = simulate(teamA, teamB, 9999999n);
  assertEq("winner", r.winner, "a");
  assertEq("rounds", r.rounds, 39);
  assertEq("crit count", r.log.filter((e) => e.crit).length, 7);
  assertEq("dmg sequence", r.log.map((e) => e.damage),
    [17, 18, 11, 11, 11, 18, 15, 11, 18, 23, 10, 18, 17, 10, 15, 2, 11, 11, 18, 15, 25, 24, 11, 25, 15, 23, 10, 23, 1, 25, 23, 36, 23, 11, 23, 10, 24, 11]);
});

Deno.test("커버리지 배틀 파리티 (variant2 오프타입 collectionShared 선택) — seed 2468013", () => {
  // A: variant2 mainframe(beast) 3마리 — 자기타입 beast는 machine에 약(×0.5)이라 선택 AI가 오프타입
  //    collectionShared(mainframe_overload=machine)를 고른다. B: variant0 machine 3마리.
  // Swift --arena-demo PARITYCOVERAGE 골든과 대조 — 오프타입 스킬 카탈로그·선택 AI가 드리프트하면
  // A가 고르는 무브(=aMoves)나 데미지가 어긋나 여기서 잡힌다.
  const snap = (kind: string, v: number) => ({ kind, variant: v, enhanceLevel: 5, progressUnits: 2 });
  const teamA: BattleTeam = [snap("fox", 2), snap("wolf", 2), snap("bear", 2)];
  const teamB: BattleTeam = [snap("scrapBot", 0), snap("antennaBot", 0), snap("pixelBot", 0)];
  // E3 재캡처 — mainframe cs rider(legacy, enemy)가 mainframe_overload에 붙어 rider draw가 추가됨.
  const r = simulate(teamA, teamB, 2468013n);
  assertEq("winner", r.winner, "b");
  assertEq("rounds", r.rounds, 43);
  // A는 오프타입 커버리지만 사용(자기타입 typeShared는 machine 상대로 손해라 선택 안 함).
  const aMoves = [...new Set(r.log.filter((e) => e.attacker === "a").map((e) => e.move))].sort();
  assertEq("A moves", aMoves, ["mainframe_overload"]);
  assertEq("dmg sequence", r.log.map((e) => e.damage),
    [9, 21, 9, 9, 23, 9, 9, 23, 9, 9, 21, 9, 9, 23, 8, 23, 9, 9, 2, 9, 8, 22, 9, 9, 21, 8, 9, 22, 9, 9, 21, 9, 9, 8, 3, 8, 7, 27, 7, 26, 8, 9, 33]);
});

// 스킬 카탈로그 전량 파리티 — 배틀 골든은 mainframe 경로 하나만 운동시켜 collectionShared type 18/19가
// 무커버다. 이 덤프로 6 generic·6 typeShared·19 collectionShared의 id/type/power를 통째로 잠근다.
// 골든은 Swift --arena-demo PARITYSKILLCAT 라인에서 캡처. 한 엔트리라도 Swift↔TS 드리프트하면 여기서 잡힌다.
const GOLD_SKILL_CATALOG =
  "PARITYSKILLCAT arcane:ult=context_window_exceeded/arcane/24 beast:ult=kernel_panic/beast/24 chaos:ult=total_outage/chaos/24 machine:ult=blue_screen/machine/24 mascot:ult=full_rollback/mascot/24 warrior:ult=rm_rf/warrior/24 ciRunners:cs=pipeline_stall/arcane/12 deprecated:cs=deprecated_strike/warrior/12 dns:cs=dns_propagation/arcane/12 emotionalSupport:cs=emotional_support/mascot/12 fridayDeploy:cs=friday_5pm/warrior/12 happyPath:cs=happy_path/beast/12 helloWorld:cs=hello_world/arcane/12 mainframe:cs=mainframe_overload/machine/12 noVerify:cs=no_verify/chaos/12 nodeModules:cs=node_modules_summon/arcane/12 npmInstall:cs=dependency_hell/chaos/12 onCall:cs=oncall_page/beast/12 oomKilled:cs=oom_kill/machine/12 rustEvangelists:cs=rewrite_in_rust/machine/12 tenXEngineer:cs=tenx_refactor/beast/12 todoSince2019:cs=tech_debt_invoice/warrior/12 tokenBurners:cs=token_burn/chaos/12 vibeCoders:cs=vibe_coding/chaos/12 wontfix:cs=wontfix_close/mascot/12 archer:u=remote_exec/warrior/14 bigDemon:u=prod_outage/chaos/14 clownCaptain:u=clown_deploy/warrior/14 dinoDragon:u=dino_stack/beast/14 fairy:u=pixie_patch/arcane/14 geralt:u=prompt_injection/warrior/14 ghost:u=zombie_process/chaos/14 gordon:u=crunch_mode/warrior/14 heroKnight:u=full_refactor/warrior/14 huntress:u=pinpoint_debug/warrior/14 kingHuman:u=legacy_monarch/arcane/14 knightF:u=blue_green/warrior/14 knightM:u=zero_downtime/warrior/14 lancer:u=zero_day/warrior/14 maskDude:u=anon_commit/warrior/14 medievalKing:u=feudal_arch/warrior/14 monk:u=zen_mode/warrior/14 mrMochi:u=infinite_scroll/mascot/14 ninjaFrog:u=stealth_deploy/warrior/14 ogre:u=monolith/chaos/14 orc:u=brute_merge/warrior/14 pawn:u=merge_conflict/warrior/14 pirateCaptain:u=code_plunder/warrior/14 plant:u=dependency_tree/arcane/14 princessSera:u=graceful_shutdown/mascot/14 pterodactyl:u=race_condition/beast/14 roboRetro:u=quantization/machine/14 skeletonLord:u=dead_code/chaos/14 skull:u=segfault/chaos/14 tRex:u=extinction_event/beast/14 visorBot:u=gradient_explosion/machine/14 warrior:u=fullstack_smash/warrior/14 whale:u=docker_whale/warrior/14 wizardM:u=hallucination/arcane/14";

Deno.test("스킬 카탈로그 파리티 — ultimate(6)·collectionShared(19)·unique(34) 전량 Swift와 대조", () => {
  const TYPES: BattleType[] = ["beast", "warrior", "chaos", "arcane", "machine", "mascot"];
  const COLLECTIONS = [
    "mainframe", "emotionalSupport", "npmInstall", "nodeModules", "dns", "deprecated",
    "vibeCoders", "tenXEngineer", "onCall", "rustEvangelists", "noVerify", "wontfix",
    "oomKilled", "fridayDeploy", "tokenBurners", "todoSince2019", "ciRunners", "happyPath", "helloWorld",
  ];
  const parts: string[] = [];
  for (const t of [...TYPES].sort()) {   // JS 기본 정렬 = Swift rawValue 정렬(전부 ASCII)과 일치
    const ult = ultimateSkill(t);
    parts.push(`${t}:ult=${ult.id}/${ult.type}/${ult.power}`);
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

// 베이스 스킬 배정 파리티(카탈로그 다양화) — 전 kind의 generic/typeShared per-kind 배정을 통째로 잠근다.
// Swift 배정 공식(assignIndex 파생)과 서버 resolved 테이블(gen_pet_meta.py emit)은 **별도 구현**이라,
// 공식·gen·members 순서 어느 쪽이 드리프트해도 Swift PARITYBASE 골든과 여기 재계산이 어긋나 잡힌다.
const GOLD_BASE_SKILLS = "PARITYBASE agentMike:g=off_and_on/mascot/8,ts=lgtm/mascot/11 akita:g=hotfix/beast/8,ts=mem_leak/beast/11 angel:g=console_log_spam/arcane/8,ts=context_overflow/arcane/11 angie:g=retry_loop/arcane/8,ts=context_overflow/arcane/11 angryPig:g=off_and_on/beast/8,ts=mem_leak/beast/11 antennaBot:g=rubber_duck/machine/8,ts=retry_storm/machine/11 archer:g=off_and_on/warrior/8,ts=breaking_change/warrior/11 armand:g=printf_debug/warrior/8,ts=prod_hotpatch/warrior/11 baldPirate:g=off_and_on/warrior/8,ts=hard_reset/warrior/11 ballooney:g=cache_purge/mascot/8,ts=pair_programming/mascot/11 barryCherry:g=todo_later/mascot/8,ts=daily_standup/mascot/11 bat:g=git_blame/beast/8,ts=mem_leak/beast/11 batBot:g=hotfix/machine/8,ts=retry_storm/machine/11 beaconBot:g=printf_debug/machine/8,ts=cron_avalanche/machine/11 bear:g=stackoverflow_paste/beast/8,ts=fork_bomb/beast/11 bee:g=rubber_duck/beast/8,ts=cpu_spike/beast/11 bigDemon:g=regenerate/chaos/8,ts=heisenbug/chaos/11 bigGuy:g=git_blame/warrior/8,ts=breaking_change/warrior/11 bigRed:g=cache_purge/chaos/8,ts=cascade_failure/chaos/11 bigZombie:g=retry_loop/chaos/8,ts=flaky_test/chaos/11 blankey:g=todo_later/chaos/8,ts=friday_deploy/chaos/11 blockyBub:g=rubber_duck/mascot/8,ts=onboarding/mascot/11 blueBird:g=console_log_spam/beast/8,ts=fork_bomb/beast/11 boar:g=off_and_on/beast/8,ts=disk_full/beast/11 bombGuy:g=stackoverflow_paste/warrior/8,ts=force_push/warrior/11 bub:g=off_and_on/mascot/8,ts=lgtm/mascot/11 bumpyBot:g=regenerate/mascot/8,ts=lgtm/mascot/11 bunny:g=rubber_duck/beast/8,ts=mem_leak/beast/11 bushly:g=cache_purge/arcane/8,ts=temperature_max/arcane/11 cat1:g=rubber_duck/beast/8,ts=mem_leak/beast/11 cat2:g=console_log_spam/beast/8,ts=cpu_spike/beast/11 cat3:g=retry_loop/beast/8,ts=fork_bomb/beast/11 cat4:g=todo_later/beast/8,ts=disk_full/beast/11 cat5:g=ctrl_cv/beast/8,ts=swap_thrash/beast/11 cat6:g=regenerate/beast/8,ts=thread_stampede/beast/11 caveGirl:g=rubber_duck/beast/8,ts=swap_thrash/beast/11 caveGirl1:g=console_log_spam/beast/8,ts=thread_stampede/beast/11 caverman:g=git_blame/beast/8,ts=disk_full/beast/11 chameleon:g=ctrl_cv/beast/8,ts=mem_leak/beast/11 cheesePuff:g=hotfix/mascot/8,ts=pair_programming/mascot/11 chiChiBird:g=regenerate/beast/8,ts=mem_leak/beast/11 chicken:g=retry_loop/beast/8,ts=disk_full/beast/11 chort:g=rubber_duck/chaos/8,ts=friday_deploy/chaos/11 clownCaptain:g=retry_loop/warrior/8,ts=hard_reset/warrior/11 cucumber:g=cache_purge/warrior/8,ts=sudo_strike/warrior/11 daikon:g=ctrl_cv/mascot/8,ts=onboarding/mascot/11 deer:g=cache_purge/beast/8,ts=swap_thrash/beast/11 devoDevil:g=stackoverflow_paste/chaos/8,ts=friday_deploy/chaos/11 diego:g=retry_loop/warrior/8,ts=prod_hotpatch/warrior/11 dinoBat:g=cache_purge/beast/8,ts=fork_bomb/beast/11 dinoBug:g=stackoverflow_paste/beast/8,ts=mem_leak/beast/11 dinoDragon:g=regenerate/beast/8,ts=disk_full/beast/11 dinoLizard:g=hotfix/beast/8,ts=swap_thrash/beast/11 dinoPlant:g=printf_debug/beast/8,ts=thread_stampede/beast/11 dinoTurtle:g=off_and_on/beast/8,ts=cpu_spike/beast/11 diverFish:g=stackoverflow_paste/mascot/8,ts=onboarding/mascot/11 doc:g=rubber_duck/arcane/8,ts=temperature_max/arcane/11 dragonMan:g=retry_loop/beast/8,ts=mem_leak/beast/11 duck:g=todo_later/beast/8,ts=swap_thrash/beast/11 dwarfF:g=printf_debug/warrior/8,ts=sudo_strike/warrior/11 dwarfM:g=stackoverflow_paste/warrior/8,ts=breaking_change/warrior/11 elfF:g=off_and_on/warrior/8,ts=prod_hotpatch/warrior/11 elfM:g=cache_purge/warrior/8,ts=force_push/warrior/11 evilWizard:g=off_and_on/warrior/8,ts=sudo_strike/warrior/11 fairy:g=console_log_spam/arcane/8,ts=temperature_max/arcane/11 fantasyWarrior:g=rubber_duck/warrior/8,ts=force_push/warrior/11 fatBird:g=ctrl_cv/beast/8,ts=thread_stampede/beast/11 fierceTooth:g=todo_later/warrior/8,ts=sudo_strike/warrior/11 fireWorm:g=console_log_spam/chaos/8,ts=friday_deploy/chaos/11 flyingEye:g=off_and_on/chaos/8,ts=friday_deploy/chaos/11 fox:g=hotfix/beast/8,ts=mem_leak/beast/11 geralt:g=console_log_spam/warrior/8,ts=breaking_change/warrior/11 ghost:g=printf_debug/chaos/8,ts=friday_deploy/chaos/11 giantRat:g=ctrl_cv/chaos/8,ts=flaky_test/chaos/11 gloppySlime:g=git_blame/arcane/8,ts=context_overflow/arcane/11 goblin:g=stackoverflow_paste/warrior/8,ts=force_push/warrior/11 goblinBrute:g=cache_purge/chaos/8,ts=heisenbug/chaos/11 goldenRetriever:g=printf_debug/beast/8,ts=cpu_spike/beast/11 gordon:g=ctrl_cv/warrior/8,ts=hard_reset/warrior/11 greatDane:g=stackoverflow_paste/beast/8,ts=fork_bomb/beast/11 grizzly:g=retry_loop/beast/8,ts=fork_bomb/beast/11 gumBot:g=cache_purge/machine/8,ts=cron_avalanche/machine/11 hermie:g=cache_purge/beast/8,ts=mem_leak/beast/11 heroKnight:g=printf_debug/warrior/8,ts=force_push/warrior/11 holly:g=todo_later/warrior/8,ts=force_push/warrior/11 huntress:g=stackoverflow_paste/warrior/8,ts=hard_reset/warrior/11 husky:g=git_blame/beast/8,ts=thread_stampede/beast/11 iceZombie:g=rubber_duck/chaos/8,ts=heisenbug/chaos/11 imp:g=retry_loop/chaos/8,ts=cascade_failure/chaos/11 jellySlime:g=console_log_spam/mascot/8,ts=onboarding/mascot/11 jumpyLumpy:g=git_blame/mascot/8,ts=daily_standup/mascot/11 kingHuman:g=retry_loop/arcane/8,ts=hallucinated_api/arcane/11 kingPig:g=cache_purge/beast/8,ts=cpu_spike/beast/11 kingSlime:g=regenerate/chaos/8,ts=friday_deploy/chaos/11 knightF:g=git_blame/warrior/8,ts=hard_reset/warrior/11 knightM:g=rubber_duck/warrior/8,ts=sudo_strike/warrior/11 lancer:g=printf_debug/warrior/8,ts=hard_reset/warrior/11 lilWiz:g=todo_later/arcane/8,ts=temperature_max/arcane/11 lionWarrior:g=todo_later/beast/8,ts=cpu_spike/beast/11 littleCaveBoy:g=ctrl_cv/beast/8,ts=fork_bomb/beast/11 lizardF:g=hotfix/warrior/8,ts=breaking_change/warrior/11 lizardM:g=printf_debug/warrior/8,ts=prod_hotpatch/warrior/11 martialHero:g=git_blame/warrior/8,ts=prod_hotpatch/warrior/11 martianRed:g=off_and_on/chaos/8,ts=heisenbug/chaos/11 maskDude:g=regenerate/warrior/8,ts=force_push/warrior/11 maskedOrc:g=todo_later/warrior/8,ts=force_push/warrior/11 medievalKing:g=cache_purge/warrior/8,ts=breaking_change/warrior/11 mimic:g=todo_later/chaos/8,ts=cascade_failure/chaos/11 miniBot:g=ctrl_cv/machine/8,ts=cron_avalanche/machine/11 miniRex:g=todo_later/beast/8,ts=cpu_spike/beast/11 moeScotty:g=console_log_spam/beast/8,ts=disk_full/beast/11 monk:g=stackoverflow_paste/warrior/8,ts=sudo_strike/warrior/11 mrChomps:g=git_blame/chaos/8,ts=flaky_test/chaos/11 mrCircuit:g=console_log_spam/machine/8,ts=cron_avalanche/machine/11 mrMan:g=ctrl_cv/mascot/8,ts=onboarding/mascot/11 mrMochi:g=retry_loop/mascot/8,ts=pair_programming/mascot/11 muddy:g=todo_later/chaos/8,ts=flaky_test/chaos/11 mushroom:g=retry_loop/arcane/8,ts=context_overflow/arcane/11 myconid:g=git_blame/chaos/8,ts=cascade_failure/chaos/11 necromancer:g=off_and_on/chaos/8,ts=cascade_failure/chaos/11 ninjaFrog:g=hotfix/warrior/8,ts=hard_reset/warrior/11 octi:g=todo_later/mascot/8,ts=daily_standup/mascot/11 ogre:g=hotfix/chaos/8,ts=cascade_failure/chaos/11 onionLad:g=console_log_spam/mascot/8,ts=lgtm/mascot/11 oposum:g=todo_later/mascot/8,ts=pair_programming/mascot/11 orangeFruit:g=rubber_duck/mascot/8,ts=onboarding/mascot/11 orc:g=off_and_on/warrior/8,ts=hard_reset/warrior/11 orcShaman:g=ctrl_cv/warrior/8,ts=hard_reset/warrior/11 orcWarrior:g=regenerate/warrior/8,ts=sudo_strike/warrior/11 orchidOwl:g=hotfix/beast/8,ts=cpu_spike/beast/11 pawn:g=cache_purge/warrior/8,ts=prod_hotpatch/warrior/11 penguin:g=printf_debug/beast/8,ts=fork_bomb/beast/11 percy:g=console_log_spam/mascot/8,ts=lgtm/mascot/11 pig:g=git_blame/beast/8,ts=fork_bomb/beast/11 pigBomber:g=console_log_spam/beast/8,ts=swap_thrash/beast/11 pigBoxer:g=rubber_duck/beast/8,ts=disk_full/beast/11 pirateCaptain:g=rubber_duck/warrior/8,ts=prod_hotpatch/warrior/11 pixelBot:g=console_log_spam/machine/8,ts=cron_avalanche/machine/11 plant:g=ctrl_cv/arcane/8,ts=temperature_max/arcane/11 pokeyBub:g=git_blame/mascot/8,ts=daily_standup/mascot/11 princessSera:g=hotfix/mascot/8,ts=pair_programming/mascot/11 pterodactyl:g=ctrl_cv/beast/8,ts=fork_bomb/beast/11 pumpkinDude:g=console_log_spam/chaos/8,ts=heisenbug/chaos/11 rabbit:g=git_blame/beast/8,ts=thread_stampede/beast/11 radish:g=regenerate/arcane/8,ts=context_overflow/arcane/11 rino:g=console_log_spam/beast/8,ts=cpu_spike/beast/11 roach:g=git_blame/beast/8,ts=cpu_spike/beast/11 roboPumpkin:g=stackoverflow_paste/machine/8,ts=regression_sweep/machine/11 roboRetro:g=retry_loop/machine/8,ts=regression_sweep/machine/11 roboTotem:g=off_and_on/machine/8,ts=retry_storm/machine/11 robotJ5:g=git_blame/machine/8,ts=regression_sweep/machine/11 robotWalky:g=rubber_duck/machine/8,ts=retry_storm/machine/11 rock1:g=printf_debug/arcane/8,ts=temperature_max/arcane/11 rock2:g=stackoverflow_paste/arcane/8,ts=context_overflow/arcane/11 rock3:g=off_and_on/arcane/8,ts=hallucinated_api/arcane/11 rocketCherry:g=regenerate/mascot/8,ts=lgtm/mascot/11 rollingNero:g=printf_debug/mascot/8,ts=daily_standup/mascot/11 saintBernard:g=off_and_on/beast/8,ts=disk_full/beast/11 schnauzer:g=cache_purge/beast/8,ts=swap_thrash/beast/11 scrapBot:g=git_blame/machine/8,ts=regression_sweep/machine/11 sentryBot:g=todo_later/machine/8,ts=retry_storm/machine/11 skelet:g=cache_purge/chaos/8,ts=flaky_test/chaos/11 skeletonG:g=ctrl_cv/chaos/8,ts=heisenbug/chaos/11 skeletonLord:g=rubber_duck/chaos/8,ts=flaky_test/chaos/11 skull:g=stackoverflow_paste/chaos/8,ts=heisenbug/chaos/11 slime:g=todo_later/arcane/8,ts=hallucinated_api/arcane/11 slug:g=printf_debug/beast/8,ts=disk_full/beast/11 snail:g=hotfix/beast/8,ts=fork_bomb/beast/11 snipCrab:g=off_and_on/beast/8,ts=thread_stampede/beast/11 spiderBot:g=retry_loop/machine/8,ts=regression_sweep/machine/11 spikeyBub:g=cache_purge/mascot/8,ts=pair_programming/mascot/11 squirmyWormy:g=rubber_duck/beast/8,ts=fork_bomb/beast/11 sunFox:g=ctrl_cv/mascot/8,ts=daily_standup/mascot/11 sunFrog:g=retry_loop/mascot/8,ts=lgtm/mascot/11 swampy:g=ctrl_cv/chaos/8,ts=friday_deploy/chaos/11 tRex:g=retry_loop/beast/8,ts=mem_leak/beast/11 tinySlug:g=stackoverflow_paste/beast/8,ts=swap_thrash/beast/11 tinyZombie:g=git_blame/chaos/8,ts=friday_deploy/chaos/11 toggle:g=regenerate/warrior/8,ts=sudo_strike/warrior/11 tommy:g=stackoverflow_paste/mascot/8,ts=onboarding/mascot/11 tracy:g=hotfix/warrior/8,ts=breaking_change/warrior/11 trunk:g=hotfix/arcane/8,ts=hallucinated_api/arcane/11 turtle:g=regenerate/beast/8,ts=cpu_spike/beast/11 twiggy:g=printf_debug/mascot/8,ts=daily_standup/mascot/11 vampireBat:g=retry_loop/chaos/8,ts=heisenbug/chaos/11 vessa:g=retry_loop/mascot/8,ts=pair_programming/mascot/11 visorBot:g=regenerate/machine/8,ts=regression_sweep/machine/11 warrior:g=hotfix/warrior/8,ts=force_push/warrior/11 whale:g=console_log_spam/warrior/8,ts=force_push/warrior/11 wispyFire:g=rubber_duck/arcane/8,ts=hallucinated_api/arcane/11 wizardF:g=cache_purge/arcane/8,ts=context_overflow/arcane/11 wizardM:g=git_blame/arcane/8,ts=hallucinated_api/arcane/11 wogol:g=printf_debug/chaos/8,ts=flaky_test/chaos/11 wolf:g=printf_debug/beast/8,ts=cpu_spike/beast/11 zombie:g=console_log_spam/chaos/8,ts=cascade_failure/chaos/11";

Deno.test("베이스 스킬 배정 파리티 — 전 kind generic/typeShared 배정 Swift와 대조", () => {
  const parts: string[] = [];
  for (const k of Object.keys(GENERIC_SKILL).sort()) {   // 195 kinds — Swift PetKind rawValue 정렬과 일치
    const g = genericSkill(k), ts = typeSharedSkill(k);
    parts.push(`${k}:g=${g.id}/${g.type}/${g.power},ts=${ts.id}/${ts.type}/${ts.power}`);
  }
  assertEq("base skills", "PARITYBASE " + parts.join(" "), GOLD_BASE_SKILLS);
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
  // E3 재캡처 — variant4 팀이 cs rider(mainframe/onCall/ciRunners)를 얻어 rider draw가 스트림에 추가됨.
  const r = simulate(teamA, teamB, 8642097n);
  assertEq("winner", r.winner, "a");
  assertEq("rounds", r.rounds, 15);
  const ultIds = new Set(["kernel_panic", "rm_rf", "total_outage", "context_window_exceeded", "blue_screen", "full_rollback"]);
  const ults = r.log.filter((e) => ultIds.has(e.move));
  assertEq("궁극기 발동 수", ults.length, 2);
  assertEq("궁극기 종류", [...new Set(ults.map((e) => e.move))].sort(), ["rm_rf"]);
  assertEq("dmg sequence", r.log.map((e) => e.damage),
    [26, 3, 25, 26, 24, 24, 39, 77, 26, 150, 145, 27, 39, 72, 76]);
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
  assertEq("rounds", r.rounds, 34);
  assertEq("fx kinds", s.kindsStr, "grant:11,heal:1,splash:6,tick:5");
  assertEq("fx ids", s.ids, "caching,deadlock,full_rollback,legacy,load_balancer,mem_leak,outage_stun");
  assertEq("fx hp", s.hp, -68);
  assertEq("dmg sequence", r.log.map((e) => e.damage),
    [3, 24, 27, 23, 27, 23, 41, 45, 30, 26, 53, 32, 29, 3, 45, 24, 29, 56, 18, 55, 35, 24, 21, 9, 20, 21, 16, 21, 27, 33, 24, 12, 110, 45]);
});

Deno.test("효과 배틀 파리티 FX2 (혼합 상성 — 실드·자힐·rate_limited 스킵·tech_debt·infinite_loop) — seed 9624325", () => {
  const A: BattleTeam = ["bigDemon", "wizardM", "mrMochi"].map(snapV4);
  const B: BattleTeam = ["fox", "warrior", "scrapBot"].map(snapV4);
  const r = simulate(A, B, 9624325n);   // Swift: seed &* 2 &+ 1
  const s = fxSummary(r);
  assertEq("winner", r.winner, "b");
  assertEq("rounds", r.rounds, 23);
  assertEq("fx kinds", s.kindsStr, "grant:6,heal:1,skip:3,tick:2");
  assertEq("fx ids", s.ids, "full_rollback,infinite_loop,load_balancer,rate_limited,tech_debt");
  assertEq("fx hp", s.hp, 4);
  assertEq("dmg sequence", r.log.map((e) => e.damage),
    [20, 41, 19, 29, 29, 30, 59, 44, 16, 245, 18, 4, 18, 18, 18, 19, 27, 18, 18, 138]);
});

// 효과 카탈로그 전량 파리티 — 효과 정의 14 + typeShared rider 6 + collectionShared rider 19(E3) +
// 궁극기 특수효과 6을 통째로 잠근다. 배틀 골든이 못 건드리는 엔트리(수치·오프타입 배정 등)도 여기서 잡힌다.
const GOLD_FX_CATALOG =
  "PARITYFXCAT autoscaling=regen/0.06/3/- bsod_lag=statModSpd/0.6/2/- caching=statModSpd/1.25/3/- deadlock=controlChance/0.0/3/0.35 firewall=statModDef/1.3/3/- hot_reload=cleanse/0.0/0/- infinite_loop=dot/0.08/3/- legacy=statModSpd/0.75/3/- load_balancer=shield/0.2/3/- mem_leak=dot/0.05/3/- optimization=statModAtk/1.25/3/- outage_stun=controlFixed/0.0/1/- rate_limited=controlFixed/0.0/2/- tech_debt=statModAtk/0.8/3/- rider.arcane=deadlock/0.25/enemy rider.beast=mem_leak/0.3/enemy rider.chaos=infinite_loop/0.25/enemy rider.machine=legacy/0.3/enemy rider.mascot=load_balancer/1.0/self rider.warrior=tech_debt/0.3/enemy csr.ciRunners=rate_limited/0.2/enemy csr.deprecated=tech_debt/0.3/enemy csr.dns=legacy/0.3/enemy csr.emotionalSupport=firewall/1.0/self csr.fridayDeploy=infinite_loop/0.25/enemy csr.happyPath=autoscaling/1.0/self csr.helloWorld=caching/1.0/self csr.mainframe=legacy/0.3/enemy csr.noVerify=infinite_loop/0.25/enemy csr.nodeModules=mem_leak/0.3/enemy csr.npmInstall=deadlock/0.25/enemy csr.onCall=rate_limited/0.2/enemy csr.oomKilled=rate_limited/0.2/enemy csr.rustEvangelists=optimization/1.0/self csr.tenXEngineer=caching/1.0/self csr.todoSince2019=tech_debt/0.3/enemy csr.tokenBurners=deadlock/0.25/enemy csr.vibeCoders=deadlock/0.25/enemy csr.wontfix=hot_reload/1.0/self ult.blue_screen=grant:bsod_lag ult.context_window_exceeded=forceCrit ult.full_rollback=selfHeal:0.25 ult.kernel_panic=splash ult.rm_rf=defIgnore ult.total_outage=grant:outage_stun";

Deno.test("효과 카탈로그 파리티 — 효과 정의·rider 배정(ts+cs)·궁극기 특수효과 전량 Swift와 대조", () => {
  // Swift Double description 재현: 정수값은 "1.0" 꼴, 그 외는 JS 기본 문자열과 일치.
  const num = (x: number) => Number.isInteger(x) ? x.toFixed(1) : String(x);
  const parts: string[] = [];
  for (const id of Object.keys(EFFECTS).sort()) {
    const d = EFFECTS[id].def;
    parts.push(`${id}=${d.kind}/${num(d.magnitude)}/${d.duration}/${d.chance == null ? "-" : num(d.chance)}`);
  }
  const TYPES: BattleType[] = ["arcane", "beast", "chaos", "machine", "mascot", "warrior"];   // rawValue 정렬
  for (const t of TYPES) {
    const r = TYPE_SHARED_RIDER[t];   // typeSharedSkill은 per-kind 시그니처 — 타입 rider는 테이블 직조회
    parts.push(`rider.${t}=${r.effectId}/${num(r.chance)}/${r.selfTarget ? "self" : "enemy"}`);
  }
  // csr — 컬렉션명 rawValue(=Swift PetCollection.rawValue) 오름차순. Swift ArenaDemo와 동일 순서.
  const COLLECTIONS = [
    "ciRunners", "deprecated", "dns", "emotionalSupport", "fridayDeploy", "happyPath", "helloWorld",
    "mainframe", "noVerify", "nodeModules", "npmInstall", "onCall", "oomKilled", "rustEvangelists",
    "tenXEngineer", "todoSince2019", "tokenBurners", "vibeCoders", "wontfix",
  ].sort();
  for (const c of COLLECTIONS) {
    const r = collectionSharedSkill(c).rider!;
    parts.push(`csr.${c}=${r.effectId}/${num(r.chance)}/${r.selfTarget ? "self" : "enemy"}`);
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
