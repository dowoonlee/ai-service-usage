// 5v5 ATB 자동전투 결정적 시뮬레이터 — 서버 authoritative. Swift `BattleEngine.swift` 와 규칙 1:1.
//
// 랭크전은 `pvp-challenge` 가 이 규칙으로 승패를 확정하고, 클라는 로그를 재생만 한다.
// 동일 (두 팀 스냅샷 + 시드) → 동일 로그·승자. RNG·반올림은 pvp_policy/enhance_engine 명세를 따른다.

import {
  BattleStats, BattleType, StatKind, Skill, computeStats, teamSynergyBonus, synergyStatMultiplier,
  matchup, collectionOf, battleTypeOf, roundAway,
  skillsFor, selectSkill, skillEffectiveness, stabMult,
} from "./pvp_policy.ts";
import { SeededRNG } from "./enhance_engine.ts";

export interface BattlePetSnapshot {
  kind: string;
  variant: number;
  enhanceLevel: number;
  progressUnits: number;
}
export type BattleTeam = BattlePetSnapshot[];   // members[0] = 리드(선봉)
export type BattleSide = "a" | "b";

export interface BattleEvent {
  round: number;            // 누적 액션 인덱스 (ATB라 "라운드" 아님)
  attacker: BattleSide;
  attackerKind: string;
  defenderKind: string;
  move: string;             // 스킬 id ("hotfix"/"mem_leak"…). 구 로그엔 "basic"/"signature"
  damage: number;
  effectiveness: number;    // 스킬 타입 상성 2.0 / 1.0 / 0.5 (구 로그엔 1.6 / 1.0 / 0.625)
  collectionMult: number;   // 밈/상성망 배수
  quip: string | null;
  parried: boolean;
  crit: boolean;            // 레인보우 크리 발동
  defenderFainted: boolean;
}
export interface BattleResult {
  winner: BattleSide | null;   // null = 무승부(타이브레이크 동률)
  rounds: number;
  log: BattleEvent[];
}

export const MAX_ROUNDS = 180;   // 5v5는 총 HP가 늘어 상향(조기 타이브레이크 무승부 방지). rage 램프가 장기전 수렴.
export const SPEED_BASE = 1000.0;

// 레인보우(최종 이로치) 크리 — 공격자가 레인보우면 확률적으로 데미지 ×critMult. Swift BattleEngine 1:1.
export const RAINBOW_VARIANT = 4;
export const RAINBOW_CRIT_CHANCE = 0.20;
export const RAINBOW_CRIT_MULT = 1.5;

// 패링(퍼펙트 가드) — DEF+SPD 조합.
export const PARRY_BASE = 0.06;
export const PARRY_SPD_WEIGHT = 0.25;
export const PARRY_DEF_WEIGHT = 0.12;
export const PARRY_MAX = 0.40;
export const PARRY_DAMAGE_MULT = 0.10;

// 격노 램프 — 장기전 데미지 점증(성장 비례 TTK 증가 → backstop 초과 방지).
export const RAGE_START = 40;
export const RAGE_STEP = 0.07;

export function parryChance(defSPD: number, defDEF: number, atkSPD: number, atkDEF: number): number {
  const sd = defSPD, sa = atkSPD, dd = defDEF, da = atkDEF;
  const spdTerm = PARRY_SPD_WEIGHT * (sd - sa) / Math.max(1, sd + sa);
  const defTerm = PARRY_DEF_WEIGHT * ((dd / Math.max(1, dd + da)) - 0.5) * 2;
  return Math.min(PARRY_MAX, Math.max(0, PARRY_BASE + spdTerm + defTerm));
}
export function rageMultiplier(action: number): number {
  return 1.0 + Math.max(0, action - RAGE_START) * RAGE_STEP;
}

interface Combatant { kind: string; type: BattleType; stats: BattleStats; hp: number; isRainbow: boolean; skills: Skill[]; }

// 팀 시너지까지 반영한 최종 전투 스탯. Swift finalStats 와 동일 소스.
export function finalStats(member: BattlePetSnapshot, team: BattleTeam): BattleStats {
  const b = teamSynergyBonus(team.map((m) => m.kind));   // 동족=전 스탯 / 동타입=대표 스탯 방향성
  const base = computeStats(member.kind, member.variant, member.enhanceLevel, member.progressUnits);
  const s = (v: number, k: StatKind) => Math.max(1, roundAway(v * synergyStatMultiplier(b, k)));
  return { hp: s(base.hp, "hp"), atk: s(base.atk, "atk"), def: s(base.def, "def"), spd: s(base.spd, "spd") };
}

function makeCombatants(team: BattleTeam): Combatant[] {
  return team.map((m) => {
    const st = finalStats(m, team);
    return {
      kind: m.kind, type: battleTypeOf(m.kind), stats: st, hp: st.hp,
      isRainbow: m.variant >= RAINBOW_VARIANT, skills: skillsFor(m.kind, m.variant),
    };
  });
}
function activeIdx(team: Combatant[]): number { return team.findIndex((c) => c.hp > 0); }
function cd(spd: number): number { return SPEED_BASE / Math.max(1, spd); }

export function simulate(teamA: BattleTeam, teamB: BattleTeam, seed: bigint): BattleResult {
  const rng = new SeededRNG(seed);
  const a = makeCombatants(teamA);
  const b = makeCombatants(teamB);
  const log: BattleEvent[] = [];

  const ai0 = activeIdx(a), bi0 = activeIdx(b);
  if (ai0 < 0 || bi0 < 0) {
    const w: BattleSide | null = ai0 >= 0 ? "a" : (bi0 >= 0 ? "b" : null);
    return { winner: w, rounds: 0, log: [] };
  }
  let aNext = cd(a[ai0].stats.spd);
  let bNext = cd(b[bi0].stats.spd);
  let actions = 0;

  while (actions < MAX_ROUNDS) {
    const ai = activeIdx(a), bi = activeIdx(b);
    if (ai < 0 || bi < 0) break;
    const aSpd = a[ai].stats.spd, bSpd = b[bi].stats.spd;
    let aGoes: boolean;
    if (Math.abs(aNext - bNext) < 1e-6) {
      aGoes = aSpd !== bSpd ? aSpd > bSpd : (rng.next() & 1n) === 0n;
    } else {
      aGoes = aNext < bNext;
    }
    actions += 1;
    const t = aGoes ? aNext : bNext;
    if (aGoes) {
      const fainted = attack(a, b, "a", actions, log, rng);
      aNext = t + cd(aSpd);
      if (fainted) { const nb = activeIdx(b); if (nb >= 0) bNext = t + cd(b[nb].stats.spd); }
    } else {
      const fainted = attack(b, a, "b", actions, log, rng);
      bNext = t + cd(bSpd);
      if (fainted) { const na = activeIdx(a); if (na >= 0) aNext = t + cd(a[na].stats.spd); }
    }
    if (activeIdx(a) < 0) return { winner: "b", rounds: actions, log };
    if (activeIdx(b) < 0) return { winner: "a", rounds: actions, log };
  }

  // backstop — 잔여 HP 합 타이브레이크.
  const sum = (t: Combatant[]) => t.reduce((acc, c) => acc + Math.max(0, c.hp), 0);
  const sumA = sum(a), sumB = sum(b);
  const winner: BattleSide | null = sumA === sumB ? null : (sumA > sumB ? "a" : "b");
  return { winner, rounds: actions, log };
}

function attack(
  from: Combatant[], to: Combatant[], attackerSide: BattleSide,
  round: number, log: BattleEvent[], rng: SeededRNG,
): boolean {
  const ai = activeIdx(from), di = activeIdx(to);
  if (ai < 0 || di < 0) return false;
  const attacker = from[ai];
  const defender = to[di];

  // 스킬 선택(결정적 AI) → 스킬 타입 상성(×2.0/×0.5) + 자속(STAB ×1.5)으로 데미지식 전환.
  const skill = selectSkill(attacker.skills, attacker.type, defender.type);
  const eff = skillEffectiveness(skill.type, defender.type);   // 로그 effectiveness = 스킬 상성
  const stab = stabMult(skill.type, attacker.type);
  const syn = matchup(collectionOf(attacker.kind), collectionOf(defender.kind));

  const rngFactor = 0.9 + 0.1 * rng.uniform01();   // [0.9, 1.0)
  const rage = rageMultiplier(round);
  const raw = (attacker.stats.atk / defender.stats.def) * skill.power * eff * stab * syn.mult * rngFactor * rage;
  const baseDmg = Math.max(1, roundAway(raw));

  // 레인보우(최종 이로치) 크리 — 공격자가 레인보우면 확률적 ×critMult. 조건부 draw라 비-레인보우
  // 배틀의 RNG 스트림·기존 골든 불변. 순서: rngFactor → (레인보우면 크리) → 패링 (Swift와 1:1).
  let critDmg = baseDmg;
  let crit = false;
  if (attacker.isRainbow) {
    crit = rng.uniform01() < RAINBOW_CRIT_CHANCE;
    if (crit) critDmg = Math.max(1, roundAway(baseDmg * RAINBOW_CRIT_MULT));
  }

  const pc = parryChance(defender.stats.spd, defender.stats.def, attacker.stats.spd, attacker.stats.def);
  const parried = rng.uniform01() < pc;
  const dmg = parried ? Math.max(1, roundAway(critDmg * PARRY_DAMAGE_MULT)) : critDmg;

  to[di].hp -= dmg;
  const fainted = to[di].hp <= 0;

  log.push({
    round,
    attacker: attackerSide,
    attackerKind: attacker.kind,
    defenderKind: defender.kind,
    move: skill.id,
    damage: dmg,
    effectiveness: eff,
    collectionMult: syn.mult,
    quip: syn.quip,
    parried,
    crit,
    defenderFainted: fainted,
  });
  return fainted;
}
