// 5v5 ATB 자동전투 결정적 시뮬레이터 — 서버 authoritative. Swift `BattleEngine.swift` 와 규칙 1:1.
//
// 랭크전은 `pvp-challenge` 가 이 규칙으로 승패를 확정하고, 클라는 로그를 재생만 한다.
// 동일 (두 팀 스냅샷 + 시드) → 동일 로그·승자. RNG·반올림은 pvp_policy/enhance_engine 명세를 따른다.

import {
  BattleStats, BattleType, StatKind, Skill, computeStats, teamSynergyBonus, synergyStatMultiplier,
  matchup, collectionOf, battleTypeOf, roundAway,
  skillsFor, selectSkill, skillEffectiveness, stabMult, ultimateSkill,
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

// 궁극기 충전 비용 — 게이지는 ①행동 시 +1 ②피격 시 +1 로 차고, 기절 시 잔여 게이지가 다음 생존
// 펫에게 승계된다(팀 게이지). 도달 시 그 행동이 궁극기(정규 스킬 대체) 후 리셋 → 장기전 다회 발동.
// 전부 이벤트 기반 = RNG 불필요·결정적. Swift BattleEngine.ultChargeCost 1:1.
// 가시성 패치(6 행동만 → 10 행동+피격+승계): 패자 궁 발동률 62/61/14% → 100/100/91% 실측, 승률 불변.
export const ULT_CHARGE_COST = 10;

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

// ── 효과 레이어 (E1 프레임) — 상태이상/버프. Swift BattleEngine 1:1. docs/plans/pet-effects.md.
// E1은 프레임만: 어떤 스킬도 효과를 부여하지 않아 배틀 결과·RNG 스트림·기존 골든이 전부 불변
// (effects 상시 빈 배열 = 전 경로 no-op). 부여는 E2 스킬 연동에서 — 그때 골든 재캡처.

export type EffectKind =
  | "dot"            // 매 자기 턴 시작 HP -= magnitude(% of maxHP)
  | "regen"          // 매 자기 턴 시작 HP += magnitude(% of maxHP), maxHP 상한
  | "statModAtk" | "statModDef" | "statModSpd"   // 지속 중 해당 스탯 × magnitude (Swift statMod(StatKind))
  | "controlFixed"   // duration 동안 무조건 턴 스킵
  | "controlChance"  // 매 턴 chance 확률로 스킵 (draw는 보유 시에만 — 스트림 보존)
  | "shield"         // flat HP 흡수막 — 소진 시 제거
  | "cleanse";       // 즉시 — 자기 디버프 전부 제거

export interface BattleEffectDef {
  id: string; kind: EffectKind;
  magnitude: number;      // dot/regen/shield: maxHP 비율, statMod*: 배수, control: 0
  duration: number;       // 지속 자기 턴 수 (cleanse는 0)
  chance: number | null;  // controlChance 스킵 확률
}
export interface ActiveEffect { effect: BattleEffectDef; remaining: number; shieldHP: number }

export const EFFECT_SLOT_CAP = 4;   // 초과 부여 시 remaining 최소(동률: 앞 인덱스)부터 밀어냄.

// StatMod 반영 스탯 — base × Π(magnitude), away-from-zero 반올림. Swift effStat 1:1. (hp는 비대상)
function effStat(base: number, stat: StatKind, effects: ActiveEffect[]): number {
  const want = stat === "atk" ? "statModAtk" : stat === "def" ? "statModDef" : stat === "spd" ? "statModSpd" : null;
  if (want === null || effects.length === 0) return base;   // E1 상시 경로 — base 그대로(반올림도 불요)
  let v = base;
  for (const e of effects) if (e.effect.kind === want) v *= e.effect.magnitude;
  return Math.max(1, roundAway(v));
}

// 자기 턴 시작 효과 틱 — DoT/Regen(≥1 보장) → remaining-- → 만료 제거. Swift tickEffects 1:1.
function tickEffects(c: Combatant): void {
  if (c.effects.length === 0) return;   // E1 상시 경로 — no-op
  for (const e of c.effects) {
    const amt = Math.max(1, roundAway(c.stats.hp * e.effect.magnitude));
    if (e.effect.kind === "dot") c.hp -= amt;
    else if (e.effect.kind === "regen") c.hp = Math.min(c.stats.hp, c.hp + amt);
  }
  for (const e of c.effects) e.remaining -= 1;
  c.effects = c.effects.filter((e) => e.remaining > 0);
}

// Control 체크 — 고정형 무조건 스킵, 확률형 draw < chance 스킵(보유 시에만 draw). Swift 1:1.
function shouldSkipTurn(c: Combatant, rng: SeededRNG): boolean {
  for (const e of c.effects) {
    if (e.effect.kind === "controlFixed") return true;
    if (e.effect.kind === "controlChance" && rng.uniform01() < (e.effect.chance ?? 0)) return true;
  }
  return false;
}

// 실드 흡수 — 앞 인덱스부터 차감, 소진 실드 제거, HP로 갈 잔여 피해 반환. Swift absorbShield 1:1.
function absorbShield(c: Combatant, dmg: number): number {
  if (!c.effects.some((e) => e.effect.kind === "shield")) return dmg;   // E1 상시 경로
  let left = dmg;
  for (const e of c.effects) {
    if (e.effect.kind !== "shield" || left <= 0) continue;
    const absorb = Math.min(e.shieldHP, left);
    e.shieldHP -= absorb;
    left -= absorb;
  }
  c.effects = c.effects.filter((e) => !(e.effect.kind === "shield" && e.shieldHP <= 0));
  return left;
}

// 효과 부여 — 동일 id refresh(중첩 없음), cleanse 즉시 디버프 제거, 슬롯 초과 시 remaining 최소 밀어냄.
// Swift grant 1:1. E2에서 스킬 시전 경로가 호출(현재 미사용 — 프레임).
export function grantEffect(c: Combatant, effect: BattleEffectDef): void {
  if (effect.kind === "cleanse") {
    c.effects = c.effects.filter((a) => {
      const k = a.effect.kind;
      if (k === "dot" || k === "controlFixed" || k === "controlChance") return false;
      if (k === "statModAtk" || k === "statModDef" || k === "statModSpd") return a.effect.magnitude >= 1;
      return true;
    });
    return;
  }
  const shieldHP = effect.kind === "shield" ? Math.max(1, roundAway(c.stats.hp * effect.magnitude)) : 0;
  const i = c.effects.findIndex((a) => a.effect.id === effect.id);
  if (i >= 0) {
    c.effects[i] = { effect, remaining: effect.duration, shieldHP };
    return;
  }
  if (c.effects.length >= EFFECT_SLOT_CAP) {
    let evict = 0;
    for (let j = 1; j < c.effects.length; j++) if (c.effects[j].remaining < c.effects[evict].remaining) evict = j;
    c.effects.splice(evict, 1);
  }
  c.effects.push({ effect, remaining: effect.duration, shieldHP });
}

interface Combatant {
  kind: string; type: BattleType; stats: BattleStats; hp: number; isRainbow: boolean;
  skills: Skill[]; ultimate: Skill | null; charge: number;
  effects: ActiveEffect[];   // 활성 효과(상한 EFFECT_SLOT_CAP). E1에선 부여자가 없어 상시 빈 배열.
}

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
    const t = battleTypeOf(m.kind);
    const rainbow = m.variant >= RAINBOW_VARIANT;
    return {
      kind: m.kind, type: t, stats: st, hp: st.hp,
      isRainbow: rainbow, skills: skillsFor(m.kind, m.variant),
      ultimate: rainbow ? ultimateSkill(t) : null, charge: 0, effects: [],
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
  let aNext = cd(effStat(a[ai0].stats.spd, "spd", a[ai0].effects));
  let bNext = cd(effStat(b[bi0].stats.spd, "spd", b[bi0].effects));
  let actions = 0;

  while (actions < MAX_ROUNDS) {
    const ai = activeIdx(a), bi = activeIdx(b);
    if (ai < 0 || bi < 0) break;
    // spd는 StatMod 효과 반영(effective) — ATB 주기·동시 tie-break 모두. E1에선 base와 동일.
    const aSpd = effStat(a[ai].stats.spd, "spd", a[ai].effects);
    const bSpd = effStat(b[bi].stats.spd, "spd", b[bi].effects);
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
      if (fainted) { const nb = activeIdx(b); if (nb >= 0) bNext = t + cd(effStat(b[nb].stats.spd, "spd", b[nb].effects)); }
    } else {
      const fainted = attack(b, a, "b", actions, log, rng);
      bNext = t + cd(bSpd);
      if (fainted) { const na = activeIdx(a); if (na >= 0) aNext = t + cd(effStat(a[na].stats.spd, "spd", a[na].effects)); }
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
  // 1) 효과 틱(자기 턴 시작) — DoT/Regen·만료 제거. DoT 자멸 시 행동 없이 종료.
  //    (E1: effects 상시 빈 배열이라 전부 no-op — E2에서 자멸 이벤트 로깅·재스케줄 정합과 함께 골든 고정.)
  tickEffects(from[ai]);
  if (from[ai].hp <= 0) return false;
  // 2) Control 체크 — 스킵 턴은 행동이 아니므로 게이지 적립 없음. (draw는 확률형 보유 시에만 — 스트림 보존)
  if (shouldSkipTurn(from[ai], rng)) return false;
  // 3) 행동
  from[ai].charge += 1;                     // 궁극기 게이지 — 행동마다 +1(결정적).
  const attacker = from[ai];                // 참조(TS)/값복사(Swift) — charge 판정은 리셋 前이라 양측 동일.
  const defender = to[di];
  // ⚠️ 파리티: 리셋(from[ai].charge=0) 이후 attacker.charge를 절대 읽지 말 것 — TS는 참조라 0, Swift는
  //    복사본이라 옛값으로 갈린다. 현재 로직은 리셋 후 charge 미사용이라 무해. effects 페이즈에서 주의.

  // 레인보우가 충전 완료면 궁극기(정규 스킬 대체) 후 게이지 리셋, 아니면 결정적 선택 AI.
  let skill: Skill;
  if (attacker.ultimate && attacker.charge >= ULT_CHARGE_COST) {
    skill = attacker.ultimate;
    from[ai].charge = 0;
  } else {
    skill = selectSkill(attacker.skills, attacker.type, defender.type);
  }
  const eff = skillEffectiveness(skill.type, defender.type);   // 로그 effectiveness = 스킬 상성
  const stab = stabMult(skill.type, attacker.type);
  const syn = matchup(collectionOf(attacker.kind), collectionOf(defender.kind));

  const rngFactor = 0.9 + 0.1 * rng.uniform01();   // [0.9, 1.0)
  const rage = rageMultiplier(round);
  // atk/def는 StatMod 효과 반영(effective) — E1에선 base와 동일.
  const atkEff = effStat(attacker.stats.atk, "atk", attacker.effects);
  const defEff = effStat(defender.stats.def, "def", defender.effects);
  const raw = (atkEff / defEff) * skill.power * eff * stab * syn.mult * rngFactor * rage;
  const baseDmg = Math.max(1, roundAway(raw));

  // 레인보우(최종 이로치) 크리 — 공격자가 레인보우면 확률적 ×critMult. 조건부 draw라 비-레인보우
  // 배틀의 RNG 스트림·기존 골든 불변. 순서: rngFactor → (레인보우면 크리) → 패링 (Swift와 1:1).
  let critDmg = baseDmg;
  let crit = false;
  if (attacker.isRainbow) {
    crit = rng.uniform01() < RAINBOW_CRIT_CHANCE;
    if (crit) critDmg = Math.max(1, roundAway(baseDmg * RAINBOW_CRIT_MULT));
  }

  // 패링 입력도 effective stat (Swift와 1:1).
  const pc = parryChance(effStat(defender.stats.spd, "spd", defender.effects), defEff,
                         effStat(attacker.stats.spd, "spd", attacker.effects), effStat(attacker.stats.def, "def", attacker.effects));
  const parried = rng.uniform01() < pc;
  const dmg = parried ? Math.max(1, roundAway(critDmg * PARRY_DAMAGE_MULT)) : critDmg;

  // Shield 흡수 — 실드부터 차감, 잔여만 HP로. (E1: 실드 미부여라 hpDmg == dmg 항상.
  //  E2에서 BattleEvent에 흡수량 필드 추가와 함께 UI HP fold 정합 처리.)
  const hpDmg = absorbShield(to[di], dmg);
  to[di].hp -= hpDmg;
  const fainted = to[di].hp <= 0;
  // 피격 충전 — 맞은 쪽도 게이지 +1(막타 피격분 포함, 아래 승계로 이전됨). 지고 있어도 맞으면서
  // 차기 때문에 양측 충전 속도가 거의 대칭 → 패자 측도 궁극기를 보게 된다(격투게임 미터 방식).
  to[di].charge += 1;
  // 게이지 승계 — 기절 시 잔여 게이지를 다음 생존 펫에게 이전(개인 게이지 → 팀 게이지).
  // ⚠️ 파리티: to[di].charge(참조라 위 +1 반영된 최신값)를 그대로 읽는다 — Swift는 지역 복사본이
  //    옛값이라 배열 원소를 강제. 순서 고정: HP 차감 → 피격 +1 → 승계 (Swift와 1:1).
  if (fainted) {
    const ni = activeIdx(to);
    if (ni >= 0) to[ni].charge += to[di].charge;
  }

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
