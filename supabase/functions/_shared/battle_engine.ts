// 5v5 ATB 자동전투 결정적 시뮬레이터 — 서버 authoritative. Swift `BattleEngine.swift` 와 규칙 1:1.
//
// 랭크전은 `pvp-challenge` 가 이 규칙으로 승패를 확정하고, 클라는 로그를 재생만 한다.
// 동일 (두 팀 스냅샷 + 시드) → 동일 로그·승자. RNG·반올림은 pvp_policy/enhance_engine 명세를 따른다.

import {
  BattleStats, BattleType, StatKind, Skill, computeStats, teamSynergyBonus, synergyStatMultiplier,
  matchup, collectionOf, battleTypeOf, roundAway,
  skillsFor, selectSkill, skillEffectiveness, stabMult, ultimateSkill,
  EffectDef, effectDef, ULT_EFFECT, ULT_DEF_IGNORE_MULT, ULT_SPLASH_MULT,
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
// 효과 이벤트(E2) — 공격 로그와 분리된 스트림(구 클라는 미지 필드 무시 → fold 오염 없음). Swift EffectEvent 1:1.
export interface EffectEvent {
  at: number;                 // 연관 액션 인덱스(BattleEvent.round 축) — tick/skip은 그 액션 직전 발생분
  side: BattleSide;           // 대상 펫의 소속
  petKind: string;
  kind: "tick" | "skip" | "grant" | "heal" | "splash";
  effectId: string | null;
  hpDelta: number | null;     // tick(±)/heal(+)/splash(−) — 실제 적용량
  fainted: boolean | null;    // splash 기절
}

export interface BattleResult {
  winner: BattleSide | null;   // null = 무승부(타이브레이크 동률)
  rounds: number;
  log: BattleEvent[];
  effectEvents?: EffectEvent[];   // E2 — 효과 없으면 생략(구 로그와 JSON 동일)
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

// ── 효과 레이어 (E1 프레임 + E2 스킬 연동) — 상태이상/버프. Swift BattleEngine 1:1. docs/plans/pet-effects.md.
// E2부터 활성: typeShared rider 6종 + happyPath 버프 + 궁극기 특수효과(§7.5)가 효과를 부여한다.
// 부여 스킬이 안 나오는 배틀(v0 팀 등)은 전 경로 no-op — RNG 스트림·구 골든 불변.
// 효과 정의(EffectDef)·카탈로그는 pvp_policy(EFFECTS) — Swift EffectCatalog 1:1.

export interface ActiveEffect { effect: EffectDef; remaining: number; shieldHP: number }

export const EFFECT_SLOT_CAP = 4;   // 초과 부여 시 remaining 최소(동률: 앞 인덱스)부터 밀어냄.

// StatMod 반영 스탯 — base × Π(magnitude), away-from-zero 반올림. Swift effStat 1:1. (hp는 비대상)
function effStat(base: number, stat: StatKind, effects: ActiveEffect[]): number {
  const want = stat === "atk" ? "statModAtk" : stat === "def" ? "statModDef" : stat === "spd" ? "statModSpd" : null;
  if (want === null || effects.length === 0) return base;   // E1 상시 경로 — base 그대로(반올림도 불요)
  let v = base;
  for (const e of effects) if (e.effect.kind === want) v *= e.effect.magnitude;
  return Math.max(1, roundAway(v));
}

// 자기 턴 시작 효과 틱 — DoT/Regen(≥1 보장, hpDelta는 실제 적용량) → remaining-- → 만료 제거. Swift 1:1.
function tickEffects(c: Combatant, side: BattleSide, round: number, events: EffectEvent[]): void {
  if (c.effects.length === 0) return;   // 미부여 배틀 상시 경로 — no-op
  for (const e of c.effects) {
    const amt = Math.max(1, roundAway(c.stats.hp * e.effect.magnitude));
    if (e.effect.kind === "dot") {
      c.hp -= amt;
      events.push({ at: round, side, petKind: c.kind, kind: "tick", effectId: e.effect.id, hpDelta: -amt, fainted: null });
    } else if (e.effect.kind === "regen") {
      const healed = Math.min(c.stats.hp - c.hp, amt);
      if (healed > 0) {
        c.hp += healed;
        events.push({ at: round, side, petKind: c.kind, kind: "tick", effectId: e.effect.id, hpDelta: healed, fainted: null });
      }
    }
  }
  for (const e of c.effects) e.remaining -= 1;
  c.effects = c.effects.filter((e) => e.remaining > 0);
}

// Control 체크 — 고정형 무조건 스킵, 확률형 draw < chance 스킵(보유 시에만 draw, 배열 순). Swift 1:1.
function shouldSkipTurn(c: Combatant, side: BattleSide, round: number, events: EffectEvent[], rng: SeededRNG): boolean {
  for (const e of c.effects) {
    if (e.effect.kind === "controlFixed") {
      events.push({ at: round, side, petKind: c.kind, kind: "skip", effectId: e.effect.id, hpDelta: null, fainted: null });
      return true;
    }
    if (e.effect.kind === "controlChance" && rng.uniform01() < (e.effect.chance ?? 0)) {
      events.push({ at: round, side, petKind: c.kind, kind: "skip", effectId: e.effect.id, hpDelta: null, fainted: null });
      return true;
    }
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
// Swift grant 1:1. attack의 rider/궁극기 grant 경로가 호출.
export function grantEffect(c: Combatant, effect: EffectDef): void {
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
  const fx: EffectEvent[] = [];   // 효과 이벤트 스트림(E2) — log와 분리(구 클라 호환)
  const withFx = (r: BattleResult): BattleResult => fx.length > 0 ? { ...r, effectEvents: fx } : r;

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
      const fainted = attack(a, b, "a", actions, log, fx, rng);
      // DoT 자멸로 공격자 선봉이 바뀌었으면 새 선봉 주기로 재스케줄(Swift 1:1).
      { const cur = activeIdx(a); if (cur >= 0) aNext = t + cd(cur === ai ? aSpd : effStat(a[cur].stats.spd, "spd", a[cur].effects)); }
      if (fainted) { const nb = activeIdx(b); if (nb >= 0) bNext = t + cd(effStat(b[nb].stats.spd, "spd", b[nb].effects)); }
    } else {
      const fainted = attack(b, a, "b", actions, log, fx, rng);
      { const cur = activeIdx(b); if (cur >= 0) bNext = t + cd(cur === bi ? bSpd : effStat(b[cur].stats.spd, "spd", b[cur].effects)); }
      if (fainted) { const na = activeIdx(a); if (na >= 0) aNext = t + cd(effStat(a[na].stats.spd, "spd", a[na].effects)); }
    }
    if (activeIdx(a) < 0) return withFx({ winner: "b", rounds: actions, log });
    if (activeIdx(b) < 0) return withFx({ winner: "a", rounds: actions, log });
  }

  // backstop — 잔여 HP 합 타이브레이크.
  const sum = (t: Combatant[]) => t.reduce((acc, c) => acc + Math.max(0, c.hp), 0);
  const sumA = sum(a), sumB = sum(b);
  const winner: BattleSide | null = sumA === sumB ? null : (sumA > sumB ? "a" : "b");
  return withFx({ winner, rounds: actions, log });
}

// RNG draw 순서(파리티 고정): (controlChance 스킵) → rngFactor → (레인보우 크리) → 패링 → (rider chance).
function attack(
  from: Combatant[], to: Combatant[], attackerSide: BattleSide,
  round: number, log: BattleEvent[], events: EffectEvent[], rng: SeededRNG,
): boolean {
  const ai = activeIdx(from), di = activeIdx(to);
  if (ai < 0 || di < 0) return false;
  // 1) 효과 틱(자기 턴 시작) — DoT/Regen·만료 제거. DoT 자멸 시 행동 없이 종료하되,
  //    게이지는 기절 승계 규칙 그대로 다음 생존 펫에게(팀 게이지 일관성).
  tickEffects(from[ai], attackerSide, round, events);
  if (from[ai].hp <= 0) {
    const ni = activeIdx(from);
    if (ni >= 0) from[ni].charge += from[ai].charge;
    return false;
  }
  // 2) Control 체크 — 스킵 턴은 행동이 아니므로 게이지 적립 없음. (draw는 확률형 보유 시에만 — 스트림 보존)
  if (shouldSkipTurn(from[ai], attackerSide, round, events, rng)) return false;
  // 3) 행동
  from[ai].charge += 1;                     // 궁극기 게이지 — 행동마다 +1(결정적).
  const attacker = from[ai];                // 참조(TS)/값복사(Swift) — charge 판정은 리셋 前이라 양측 동일.
  const defender = to[di];
  // ⚠️ 파리티: 리셋(from[ai].charge=0) 이후 attacker.charge를 절대 읽지 말 것 — TS는 참조라 0, Swift는
  //    복사본이라 옛값으로 갈린다. 효과 관련 읽기도 부여 지점 이전에 끝내고, 변이는 배열 원소로만(Swift와 1:1).

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

  // 궁극기 특수효과(E2, §7.5) — 히트 변형은 아래 계산에, 부여/자힐은 히트 해소 후에 적용.
  const ultFx = skill.tier === "ultimate" ? (ULT_EFFECT[skill.id] ?? null) : null;

  const rngFactor = 0.9 + 0.1 * rng.uniform01();   // [0.9, 1.0)
  const rage = rageMultiplier(round);
  // atk/def는 StatMod 효과 반영(effective). rm_rf 방어무시는 defEff × ULT_DEF_IGNORE_MULT로 계산.
  const atkEff = effStat(attacker.stats.atk, "atk", attacker.effects);
  const defEff = effStat(defender.stats.def, "def", defender.effects);
  const defCalc = ultFx?.t === "defIgnore" ? Math.max(1, roundAway(defEff * ULT_DEF_IGNORE_MULT)) : defEff;
  const raw = (atkEff / defCalc) * skill.power * eff * stab * syn.mult * rngFactor * rage;
  const baseDmg = Math.max(1, roundAway(raw));

  // 레인보우(최종 이로치) 크리 — 공격자가 레인보우면 확률적 ×critMult. 조건부 draw라 비-레인보우
  // 배틀의 RNG 스트림·기존 골든 불변. 순서: rngFactor → (레인보우면 크리) → 패링 (Swift와 1:1).
  // 확정 크리(context_window_exceeded): draw는 반드시 소비, 결과만 강제 true(스트림 보존 — §7.5).
  let critDmg = baseDmg;
  let crit = false;
  if (attacker.isRainbow) {
    crit = rng.uniform01() < RAINBOW_CRIT_CHANCE;
    if (ultFx?.t === "forceCrit") crit = true;
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

  const defenderSide: BattleSide = attackerSide === "a" ? "b" : "a";

  // 광역(kernel_panic) — 후열 생존 전원에 최종 데미지 × ULT_SPLASH_MULT(개별 실드 흡수).
  // 배열 앞 인덱스부터 순차(결정적) — 스플래시 기절도 피격 충전·게이지 승계 규칙 동일 적용. Swift 1:1.
  if (ultFx?.t === "splash") {
    for (let j = 0; j < to.length; j++) {
      if (j === di || to[j].hp <= 0) continue;
      const sdmg = Math.max(1, roundAway(dmg * ULT_SPLASH_MULT));
      const sHp = absorbShield(to[j], sdmg);
      to[j].hp -= sHp;
      to[j].charge += 1;
      const sFaint = to[j].hp <= 0;
      events.push({ at: round, side: defenderSide, petKind: to[j].kind, kind: "splash", effectId: null, hpDelta: -sHp, fainted: sFaint });
      if (sFaint) { const ni = activeIdx(to); if (ni >= 0) to[ni].charge += to[j].charge; }
    }
  }

  // 궁극기 부여/자힐(§7.5) — 부여는 적 활성 대상(막타 기절 시 생략), 자힐은 실제 회복량만 기록. Swift 1:1.
  if (ultFx?.t === "grant") {
    const def = effectDef(ultFx.effectId);
    if (to[di].hp > 0 && def) {
      grantEffect(to[di], def);
      events.push({ at: round, side: defenderSide, petKind: to[di].kind, kind: "grant", effectId: ultFx.effectId, hpDelta: null, fainted: null });
    }
  } else if (ultFx?.t === "selfHeal") {
    const amt = Math.max(1, roundAway(from[ai].stats.hp * ultFx.frac));
    const healed = Math.min(from[ai].stats.hp - from[ai].hp, amt);
    if (healed > 0) {
      from[ai].hp += healed;
      events.push({ at: round, side: attackerSide, petKind: from[ai].kind, kind: "heal", effectId: skill.id, hpDelta: healed, fainted: null });
    }
  }

  // 스킬 부수효과(rider, §3) — chance 1.0 확정(draw 없음), 확률형 draw < chance.
  // 적 대상 rider는 막타 기절 시 draw까지 생략(결정적 — Swift 1:1).
  const rider = skill.rider;
  if (rider) {
    const def = effectDef(rider.effectId);
    if (def) {
      if (rider.selfTarget) {
        if (rider.chance >= 1.0 || rng.uniform01() < rider.chance) {
          grantEffect(from[ai], def);
          events.push({ at: round, side: attackerSide, petKind: from[ai].kind, kind: "grant", effectId: rider.effectId, hpDelta: null, fainted: null });
        }
      } else if (to[di].hp > 0) {
        if (rider.chance >= 1.0 || rng.uniform01() < rider.chance) {
          grantEffect(to[di], def);
          events.push({ at: round, side: defenderSide, petKind: to[di].kind, kind: "grant", effectId: rider.effectId, hpDelta: null, fainted: null });
        }
      }
    }
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
