// 아레나(PvP) 정책 상수 + 스탯 파생 + 펫간 상성 — 서버 authoritative SSOT.
//
// Swift `PetBattleStats.swift` / `PetSynergy.swift` 와 값·규칙 1:1. 동일 입력 → 동일 스탯/상성.
// 배틀·강화 엔진(`battle_engine.ts` / `enhance_engine.ts`)이 이 모듈을 참조한다.
// 펫별 rarity/collection 은 클라 하드코딩이라 서버엔 없어 `pet_meta_gen.ts`(Swift 생성)로 포팅.
//
// 반올림 규약: Swift `Int(x.rounded())` = round-half-away-from-zero. 입력이 전부 양수라 JS
// `Math.round`와 동일하지만, 명세 고정을 위해 `roundAway`를 쓴다(음수 안전).

import { RARITY, COLLECTION, UNIQUE_SKILL } from "./pet_meta_gen.ts";

// round half away from zero (Swift .rounded() 기본 규약).
export function roundAway(x: number): number {
  return x >= 0 ? Math.floor(x + 0.5) : Math.ceil(x - 0.5);
}

export type Rarity = "common" | "rare" | "epic" | "legendary" | "mythic";
export type BattleType = "beast" | "warrior" | "chaos" | "arcane" | "machine" | "mascot";

export interface BattleStats { hp: number; atk: number; def: number; spd: number; }
export function statTotal(s: BattleStats): number { return s.hp + s.atk + s.def + s.spd; }

// ─────────────────────────────────────────────────────────────────────────────
// 펫 메타 해석 (kind → rarity / collection / battleType)

export function rarityOf(kind: string): Rarity {
  return (RARITY[kind] as Rarity) ?? "common";   // pool에 없으면 Common fallback (Swift와 동일)
}
export function collectionOf(kind: string): string {
  return COLLECTION[kind] ?? "mainframe";
}

// 컬렉션(19) → 배틀 타입(6). Swift PetBattleStats 의 battleType 확장과 1:1.
const COLLECTION_TYPE: Record<string, BattleType> = {
  mainframe: "beast", emotionalSupport: "beast", npmInstall: "beast",
  nodeModules: "beast", dns: "beast", deprecated: "beast",
  vibeCoders: "warrior", tenXEngineer: "warrior", onCall: "warrior",
  rustEvangelists: "warrior", noVerify: "warrior",
  wontfix: "chaos", oomKilled: "chaos", fridayDeploy: "chaos",
  tokenBurners: "arcane", todoSince2019: "arcane",
  ciRunners: "machine",
  happyPath: "mascot", helloWorld: "mascot",
};
export function battleTypeOf(kind: string): BattleType {
  return COLLECTION_TYPE[collectionOf(kind)] ?? "beast";
}

// ─────────────────────────────────────────────────────────────────────────────
// 타입 6-사이클 상성

// 이 타입이 강하게 이기는 상대. machine→beast→chaos→arcane→mascot→warrior→machine.
const BEATS: Record<BattleType, BattleType> = {
  machine: "beast", beast: "chaos", chaos: "arcane",
  arcane: "mascot", mascot: "warrior", warrior: "machine",
};
// [레거시 — 배틀 미사용] 패시브 타입 상성. 스킬 전환(Phase A) 이후 배틀은 skillEffectiveness(×2.0/×0.5)를
// 쓴다. 사이클(BEATS) 자체는 skillEffectiveness가 재사용하는 SSOT라 상수/함수는 남겨둔다.
export const TYPE_SUPER = 1.6;
export const TYPE_WEAK = 0.625;   // = 1 / 1.6
export function effectiveness(attacker: BattleType, defender: BattleType): number {
  if (BEATS[attacker] === defender) return TYPE_SUPER;
  if (BEATS[defender] === attacker) return TYPE_WEAK;
  return 1.0;
}

// ─────────────────────────────────────────────────────────────────────────────
// 스킬 (Phase A) — Swift PetSkills.swift 와 규칙 1:1. 설계 SSOT: docs/plans/pet-skills.md.
// variant 0 = generic("핫픽스") / variant 1 = typeShared(타입 6종). 타입에서 규칙 파생(per-kind 데이터 없음).

export type SkillTier = "generic" | "typeShared" | "collectionShared" | "unique" | "ultimate";

// 스킬 부수효과(rider, E2 — pet-effects.md §3). chance 1.0 = 확정(rng draw 미소비),
// (0,1) = draw < chance. selfTarget: true = 시전자 자버프, false = 적 활성 디버프(막타 기절 시 draw까지 생략).
// Swift SkillRider 1:1.
export interface SkillRider { effectId: string; chance: number; selfTarget: boolean }
export interface Skill { id: string; name: string; type: BattleType; power: number; tier: SkillTier; rider?: SkillRider }

// ─────────────────────────────────────────────────────────────────────────────
// 효과 카탈로그 (E2) — pet-effects.md §2 + §7.5. Swift EffectCatalog 1:1.
// 스킬 id와 같은 이름의 효과(mem_leak 등)는 별도 네임스페이스(그 스킬이 부여하는 효과) — 충돌 아님.

export interface EffectDef {
  id: string;
  kind: "dot" | "regen" | "statModAtk" | "statModDef" | "statModSpd" | "controlFixed" | "controlChance" | "shield" | "cleanse";
  magnitude: number;      // dot/regen/shield: maxHP 비율, statMod*: 배수, control: 0
  duration: number;
  chance: number | null;  // controlChance 스킵 확률
}
export const EFFECTS: Record<string, { name: string; def: EffectDef }> = (() => {
  const fx = (id: string, name: string, kind: EffectDef["kind"], magnitude: number, duration: number, chance: number | null = null) =>
    [id, { name, def: { id, kind, magnitude, duration, chance } }] as const;
  return Object.fromEntries([
    // 상태이상(디버프)
    fx("mem_leak",      "메모리 릭",      "dot", 0.05, 3),
    fx("infinite_loop", "무한 루프",      "dot", 0.08, 3),
    fx("deadlock",      "데드락",         "controlChance", 0, 3, 0.35),
    fx("rate_limited",  "레이트 리밋",    "controlFixed", 0, 2),
    fx("tech_debt",     "기술 부채",      "statModAtk", 0.80, 3),
    fx("legacy",        "레거시",         "statModSpd", 0.75, 3),
    // 버프(자신)
    fx("optimization",  "최적화",         "statModAtk", 1.25, 3),
    fx("firewall",      "방화벽",         "statModDef", 1.30, 3),
    fx("caching",       "캐싱",           "statModSpd", 1.25, 3),
    fx("load_balancer", "로드 밸런서",    "shield", 0.20, 3),
    fx("autoscaling",   "오토스케일링",   "regen", 0.06, 3),
    fx("hot_reload",    "핫 리로드",      "cleanse", 0, 0),
    // 궁극기 부여 전용 (§7.5 — 카탈로그판과 지속이 달라 별도 id)
    fx("outage_stun",   "전면 장애",      "controlFixed", 0, 1),
    fx("bsod_lag",      "블루 스크린",    "statModSpd", 0.60, 2),
  ]);
})();
export function effectDef(id: string): EffectDef | null { return EFFECTS[id]?.def ?? null; }

// 스킬 상성 — 타입 6-사이클(BEATS) 재사용, 배수만 ×2.0/×0.5(패시브 ×1.6/0.625 대체).
export const SKILL_SUPER = 2.0;
export const SKILL_WEAK = 0.5;
export const STAB_MULT = 1.5;
export const GENERIC_POWER = 8.0;
export const TYPE_SHARED_POWER = 11.0;

export function skillEffectiveness(skillType: BattleType, defender: BattleType): number {
  if (BEATS[skillType] === defender) return SKILL_SUPER;
  if (BEATS[defender] === skillType) return SKILL_WEAK;
  return 1.0;
}
// 자속(STAB) — 스킬 타입 == 펫 타입이면 ×1.5.
export function stabMult(skillType: BattleType, petType: BattleType): number {
  return skillType === petType ? STAB_MULT : 1.0;
}

const TYPE_SHARED_SKILL: Record<BattleType, [string, string]> = {
  beast: ["mem_leak", "메모리 릭"],
  warrior: ["force_push", "강제 푸시"],
  chaos: ["friday_deploy", "금요일 배포"],
  arcane: ["context_overflow", "컨텍스트 폭발"],
  machine: ["regression_sweep", "회귀 스윕"],
  mascot: ["onboarding", "온보딩"],
};
// typeShared 부수효과(E2) — 타입당 1개, 밈 정합. 디버프 25~30% / 버프(onboarding) 확정 자부여.
// Swift typeSharedRiderTable 1:1. 수치는 밸런스 튜닝 대상.
const TYPE_SHARED_RIDER: Record<BattleType, SkillRider> = {
  beast:   { effectId: "mem_leak", chance: 0.30, selfTarget: false },
  warrior: { effectId: "tech_debt", chance: 0.30, selfTarget: false },
  chaos:   { effectId: "infinite_loop", chance: 0.25, selfTarget: false },
  arcane:  { effectId: "deadlock", chance: 0.25, selfTarget: false },
  machine: { effectId: "legacy", chance: 0.30, selfTarget: false },
  mascot:  { effectId: "load_balancer", chance: 1.0, selfTarget: true },
};
export function genericSkill(type: BattleType): Skill {
  return { id: "hotfix", name: "핫픽스", type, power: GENERIC_POWER, tier: "generic" };
}
export function typeSharedSkill(type: BattleType): Skill {
  const [id, name] = TYPE_SHARED_SKILL[type];
  return { id, name, type, power: TYPE_SHARED_POWER, tier: "typeShared", rider: TYPE_SHARED_RIDER[type] };
}

export const COLLECTION_SHARED_POWER = 12.0;
// collectionShared — 컬렉션 밈 스킬(variant 2). **오프타입**(각 컬렉션 자기 배틀타입과 다름)이라
// variant 2부터 커버리지 선택이 생긴다. Swift SkillCatalog.collectionSharedTable 와 id/name/type 1:1.
const COLLECTION_SHARED_SKILL: Record<string, [string, string, BattleType]> = {
  mainframe: ["mainframe_overload", "메인프레임 과부하", "machine"],
  emotionalSupport: ["emotional_support", "정서적 지지", "mascot"],
  npmInstall: ["dependency_hell", "의존성 지옥", "chaos"],
  nodeModules: ["node_modules_summon", "node_modules 소환", "arcane"],
  dns: ["dns_propagation", "DNS 전파 지연", "arcane"],
  deprecated: ["deprecated_strike", "@deprecated", "warrior"],
  vibeCoders: ["vibe_coding", "바이브 코딩", "chaos"],
  tenXEngineer: ["tenx_refactor", "10x 리팩터", "beast"],
  onCall: ["oncall_page", "온콜 호출", "beast"],
  rustEvangelists: ["rewrite_in_rust", "Rust로 재작성", "machine"],
  noVerify: ["no_verify", "--no-verify", "chaos"],
  wontfix: ["wontfix_close", "won't fix", "mascot"],
  oomKilled: ["oom_kill", "OOM 킬러", "machine"],
  fridayDeploy: ["friday_5pm", "금요일 5시 배포", "warrior"],
  tokenBurners: ["token_burn", "토큰 소각", "chaos"],
  todoSince2019: ["tech_debt_invoice", "기술부채 청구서", "warrior"],
  ciRunners: ["pipeline_stall", "파이프라인 병목", "arcane"],
  happyPath: ["happy_path", "해피 패스", "beast"],
  helloWorld: ["hello_world", "Hello, World!", "arcane"],
};
export function collectionSharedSkill(collection: string): Skill {
  // fail-closed: 미매핑 컬렉션은 조용히 잘못된 타입으로 대체하지 않고 던진다(Swift 강제언랩과 대칭).
  // 조용한 폴백은 authoritative 랭크 결과를 틀린 스킬타입으로 오염시키는데, 던지면 배포/테스트에서 잡힌다.
  const e = COLLECTION_SHARED_SKILL[collection];
  if (!e) throw new Error(`collectionSharedSkill: 미매핑 컬렉션 "${collection}" (Swift collectionSharedTable와 동기화 필요)`);
  const [id, name, type] = e;
  return { id, name, type, power: COLLECTION_SHARED_POWER, tier: "collectionShared", rider: COLLECTION_SHARED_RIDER[collection] };
}
// collectionShared rider — 19종 전량(E3). 디버프 20~30% / 버프 확정 자부여. Swift 1:1.
const COLLECTION_SHARED_RIDER: Record<string, SkillRider> = {
  // 디버프 (적 활성)
  mainframe:     { effectId: "legacy", chance: 0.30, selfTarget: false },
  npmInstall:    { effectId: "deadlock", chance: 0.25, selfTarget: false },
  nodeModules:   { effectId: "mem_leak", chance: 0.30, selfTarget: false },
  dns:           { effectId: "legacy", chance: 0.30, selfTarget: false },
  deprecated:    { effectId: "tech_debt", chance: 0.30, selfTarget: false },
  vibeCoders:    { effectId: "deadlock", chance: 0.25, selfTarget: false },
  onCall:        { effectId: "rate_limited", chance: 0.20, selfTarget: false },
  noVerify:      { effectId: "infinite_loop", chance: 0.25, selfTarget: false },
  oomKilled:     { effectId: "rate_limited", chance: 0.20, selfTarget: false },
  fridayDeploy:  { effectId: "infinite_loop", chance: 0.25, selfTarget: false },
  tokenBurners:  { effectId: "deadlock", chance: 0.25, selfTarget: false },
  todoSince2019: { effectId: "tech_debt", chance: 0.30, selfTarget: false },
  ciRunners:     { effectId: "rate_limited", chance: 0.20, selfTarget: false },
  // 버프 (자신, 확정)
  emotionalSupport: { effectId: "firewall", chance: 1.0, selfTarget: true },
  tenXEngineer:  { effectId: "caching", chance: 1.0, selfTarget: true },
  rustEvangelists: { effectId: "optimization", chance: 1.0, selfTarget: true },
  wontfix:       { effectId: "hot_reload", chance: 1.0, selfTarget: true },
  happyPath:     { effectId: "autoscaling", chance: 1.0, selfTarget: true },
  helloWorld:    { effectId: "caching", chance: 1.0, selfTarget: true },
};

export const UNIQUE_POWER = 14.0;
// unique — Epic+ per-kind 고유기(variant 3). **자기타입 시그니처**. id/name은 pet_meta_gen.UNIQUE_SKILL
// (Swift uniqueTable에서 gen), type은 battleTypeOf 파생, power 상수. Swift SkillCatalog.unique 1:1.
// 저레어(Common/Rare)는 매핑 없음 → null(variant 3에서도 슬롯 추가 안 됨).
export function uniqueSkill(kind: string): Skill | null {
  const u = UNIQUE_SKILL[kind];
  if (!u) return null;
  // rider는 자기 타입 typeShared rider 상속(사실상 타입 특성) — 미상속 시 Epic+는 unique가 ts를 항상
  // 지배해(21 > 16.5) rider가 영영 발동하지 않는다. Swift SkillCatalog.unique 1:1.
  const t = battleTypeOf(kind);
  return { id: u[0], name: u[1], type: t, power: UNIQUE_POWER, tier: "unique", rider: TYPE_SHARED_RIDER[t] };
}

export const ULTIMATE_POWER = 24.0;
// ultimate — 레인보우(variant 4) 궁극기. 타입별 6종, 자기타입 시그니처 power 24. 충전 게이지가 차면
// 발동(battle_engine). 효과는 effects 페이즈로 분리. Swift SkillCatalog.ultimateTable 1:1.
const ULTIMATE_SKILL: Record<BattleType, [string, string]> = {
  beast: ["kernel_panic", "커널 패닉"],
  warrior: ["rm_rf", "rm -rf --no-preserve-root"],
  chaos: ["total_outage", "전면 장애"],
  arcane: ["context_window_exceeded", "컨텍스트 초과"],
  machine: ["blue_screen", "블루 스크린"],
  mascot: ["full_rollback", "전체 롤백"],
};
export function ultimateSkill(type: BattleType): Skill {
  const [id, name] = ULTIMATE_SKILL[type];
  return { id, name, type, power: ULTIMATE_POWER, tier: "ultimate" };
}

// 궁극기 특수효과(E2, §7.5) — 히트 변형 3종 + 지속/즉시 3종. Swift ultimateEffectTable 1:1.
export type UltEffect =
  | { t: "defIgnore" } | { t: "forceCrit" } | { t: "splash" }
  | { t: "grant"; effectId: string } | { t: "selfHeal"; frac: number };
export const ULT_DEF_IGNORE_MULT = 0.3;
export const ULT_SPLASH_MULT = 0.3;
export const ULT_EFFECT: Record<string, UltEffect> = {
  rm_rf:                   { t: "defIgnore" },
  context_window_exceeded: { t: "forceCrit" },
  kernel_panic:            { t: "splash" },
  total_outage:            { t: "grant", effectId: "outage_stun" },
  blue_screen:             { t: "grant", effectId: "bsod_lag" },
  full_rollback:           { t: "selfHeal", frac: 0.25 },
};

// variant까지 해금한 정규 스킬(슬롯 순). Swift SkillCatalog.skills 1:1.
export function skillsFor(kind: string, variant: number): Skill[] {
  const t = battleTypeOf(kind);
  const out = [genericSkill(t)];                    // 슬롯0 — 항상 보유
  if (variant >= 1) out.push(typeSharedSkill(t));   // 슬롯1 — 이로치1
  if (variant >= 2) out.push(collectionSharedSkill(collectionOf(kind)));   // 슬롯2 — 이로치2(오프타입 커버리지)
  if (variant >= 3) { const u = uniqueSkill(kind); if (u) out.push(u); }   // 슬롯3 — 이로치3, Epic+ 고유기
  return out;
}
export function skillScore(s: Skill, attackerType: BattleType, defenderType: BattleType): number {
  return s.power * skillEffectiveness(s.type, defenderType) * stabMult(s.type, attackerType);
}
// 결정적 선택 AI — 점수 최대, 동점이면 슬롯 인덱스 낮은 것(strict >). Swift SkillCatalog.select 1:1.
// 전제: skills 비지 않음(skillsFor가 generic을 항상 첫 슬롯에 둠). 파리티: score가 A/B1에선 dyadic이라
// Swift↔JS 비트동일 — B2에서 비-dyadic power/배수 도입 시 tie-break 드리프트 주의(dyadic 유지).
//
// E3 확장 — 자기버프 우선(상태 기반, RNG 없음): 자기 대상 rider 스킬 중 ①일반 버프는 미보유일 때
// ②cleanse는 자기에게 디버프가 있을 때를 "우선 후보"로 삼고, 있으면 그중 점수 최대를 고른다.
// activeEffectIds/hasDebuff 미전달(기본 빈/false)이면 기존 최대 데미지 선택과 동일.
export function selectSkill(
  skills: Skill[], attackerType: BattleType, defenderType: BattleType,
  activeEffectIds: Set<string> = new Set(), hasDebuff = false,
): Skill {
  const pick = (cands: Skill[]): Skill => {
    let best = cands[0];
    let bestScore = skillScore(best, attackerType, defenderType);
    for (let i = 1; i < cands.length; i++) {
      const sc = skillScore(cands[i], attackerType, defenderType);
      if (sc > bestScore) { bestScore = sc; best = cands[i]; }
    }
    return best;
  };
  const buffWanted = skills.filter((s) => {
    const r = s.rider;
    if (!r || !r.selfTarget) return false;
    const def = effectDef(r.effectId);
    if (!def) return false;
    if (def.kind === "cleanse") return hasDebuff;
    return !activeEffectIds.has(r.effectId);
  });
  return pick(buffWanted.length > 0 ? buffWanted : skills);
}

// base 를 4스탯으로 분배하는 archetype 배수.
const ARCHETYPE: Record<BattleType, [number, number, number, number]> = {
  beast: [1.00, 1.05, 0.95, 1.10],
  warrior: [1.00, 1.25, 0.95, 0.90],
  arcane: [0.85, 1.30, 0.80, 1.05],
  chaos: [0.90, 1.20, 0.85, 1.10],
  machine: [1.05, 0.95, 1.35, 0.75],
  mascot: [1.35, 0.85, 1.10, 0.85],
};

// ─────────────────────────────────────────────────────────────────────────────
// 스탯 파생 (base × archetype × 성장 × variant)

const RARITY_BASE: Record<Rarity, number> = {
  common: 40, rare: 48, epic: 56, legendary: 66, mythic: 78,
};

// 강화 레벨 +0…+15 스탯 보너스(가속형). index = 강화 레벨.
export const ENHANCE_BONUS = [
  0, 0.04, 0.08, 0.13, 0.18, 0.25, 0.30, 0.36, 0.43, 0.51, 0.60, 0.70, 0.82, 0.95, 1.07, 1.20,
];
export const VARIANT_BONUS = [0, 0.03, 0.06, 0.10, 0.18];   // 기본/이로치1·2·3/레인보우 (전 스탯 곱)
export const MASTERY_MAX = 0.15;
export const OVERFLOW_START_UNITS = 8.0;   // 숙련도 만렙 유닛 (Swift PetOwnership.overflowStartUnits)
export const STAT_CAP_MULT = 2.6;
export const MAX_ENHANCE_LEVEL = 15;

function clampIdx(i: number, hi: number): number { return Math.min(Math.max(0, i), hi); }

export function masteryBonus(progressUnits: number): number {
  if (OVERFLOW_START_UNITS <= 0) return 0;
  return MASTERY_MAX * Math.min(1.0, Math.max(0, progressUnits) / OVERFLOW_START_UNITS);
}
export function enhanceMultiplier(level: number): number {
  return ENHANCE_BONUS[clampIdx(level, MAX_ENHANCE_LEVEL)];
}
export function variantMultiplier(variant: number): number {
  return VARIANT_BONUS[clampIdx(variant, VARIANT_BONUS.length - 1)];
}
export function growthMultiplier(enhanceLevel: number, progressUnits: number): number {
  return Math.min(STAT_CAP_MULT, 1.0 + masteryBonus(progressUnits) + enhanceMultiplier(enhanceLevel));
}

export const PROFILE_SPREAD = 0.25;   // 개체별 스탯 프로필 spread(±). Swift PetBattleStats.profileSpread 와 동일.

// FNV-1a 32비트 — kind(ASCII) 결정적 해시. Swift PetBattleStats.fnv1a32 와 bit-identical.
function fnv1a32(s: string): number {
  let h = 2166136261;
  for (let i = 0; i < s.length; i++) h = Math.imul(h ^ s.charCodeAt(i), 16777619) >>> 0;
  return h >>> 0;
}
// 타입 archetype에 kind별 결정적 tilt → 합 보존 정규화(총 전투력 유지, 분배만 차등). Swift profileArchetype 1:1.
function kindArchetype(kind: string): [number, number, number, number] {
  const a = ARCHETYPE[battleTypeOf(kind)];
  const tilt = (i: number) => 1.0 + PROFILE_SPREAD * (fnv1a32(`${kind}#${i}`) / 4294967296.0 * 2.0 - 1.0);
  const e0 = a[0] * tilt(0), e1 = a[1] * tilt(1), e2 = a[2] * tilt(2), e3 = a[3] * tilt(3);
  const archSum = a[0] + a[1] + a[2] + a[3];
  const effSum = e0 + e1 + e2 + e3;
  const norm = effSum > 0 ? archSum / effSum : 1.0;
  return [e0 * norm, e1 * norm, e2 * norm, e3 * norm];
}

// HP 전용 스케일 — atk/def 불변, HP만 곱해 TTK↑(궁극기 충전 ~1회/대전 + 스윙 완화). Swift PetBattleStats.hpScale 1:1.
export const HP_SCALE = 1.5;

export function computeStats(
  kind: string, variant: number, enhanceLevel: number, progressUnits: number,
): BattleStats {
  const base = RARITY_BASE[rarityOf(kind)];
  const a = kindArchetype(kind);
  const growth = growthMultiplier(enhanceLevel, progressUnits);
  const vb = 1.0 + variantMultiplier(variant);
  const stat = (arch: number) => Math.max(1, roundAway(base * arch * growth * vb));
  return { hp: Math.max(1, roundAway(base * a[0] * growth * vb * HP_SCALE)), atk: stat(a[1]), def: stat(a[2]), spd: stat(a[3]) };
}

// ─────────────────────────────────────────────────────────────────────────────
// 펫간 상성 3층 (PetSynergy.swift 1:1)

export const MEME_MULT = 1.30;
export const NETWORK_MULT = 1.12;

// B. 밈 라이벌 — attacker ▶ defender 큰 보너스 + 대사. 역방향은 1/MEME_MULT.
const MEME_RIVALS: Record<string, Record<string, string>> = {
  noVerify: { ciRunners: "--no-verify. CI? 그게 뭔데." },
  dns: { mainframe: "네 컴퓨터가 아니라 DNS였어." },
  onCall: { fridayDeploy: "삐삐 울렸다. 금요일 장애, 진압." },
  rustEvangelists: { deprecated: "그거, Rust로 다시 짜면 되잖아?" },
  oomKilled: { nodeModules: "node_modules가 메모리를 다 먹었다." },
  wontfix: { todoSince2019: "닫아도 닫아도 살아 돌아온다." },
  tenXEngineer: { vibeCoders: "vibe로는 안 돼. 실력으로 갈아넣는다." },
  tokenBurners: { npmInstall: "의존성 지옥? context에 통째로 태워버려." },
  fridayDeploy: { happyPath: "금요일 5시. 평화는 끝났다." },
};
// C. 컬렉션 상성망 — 작은 보너스, 대사 없음. 역방향 역수.
const NETWORK_STRONG: Record<string, string[]> = {
  mainframe: ["deprecated"],
  emotionalSupport: ["oomKilled"],
  vibeCoders: ["todoSince2019"],
  npmInstall: ["happyPath"],
  ciRunners: ["wontfix"],
  tokenBurners: ["helloWorld"],
  onCall: ["oomKilled"],
  rustEvangelists: ["npmInstall"],
};

export interface Matchup { mult: number; quip: string | null; }
// 우선순위: 밈(1.30) > 상성망(1.12) > 중립. attacker/defender 는 컬렉션 문자열.
export function matchup(attacker: string, defender: string): Matchup {
  const q = MEME_RIVALS[attacker]?.[defender];
  if (q !== undefined) return { mult: MEME_MULT, quip: q };
  if (MEME_RIVALS[defender]?.[attacker] !== undefined) return { mult: 1.0 / MEME_MULT, quip: null };
  if (NETWORK_STRONG[attacker]?.includes(defender)) return { mult: NETWORK_MULT, quip: null };
  if (NETWORK_STRONG[defender]?.includes(attacker)) return { mult: 1.0 / NETWORK_MULT, quip: null };
  return { mult: 1.0, quip: null };
}

// A. 팀 시너지 — 동족(컬렉션)=전 스탯 곱 / 동타입=그 타입 대표 스탯만 방향성 버프. Swift TeamSynergy 1:1.
const TEAM_COLLECTION_BONUS: Record<number, number> = { 2: 0.05, 3: 0.10, 4: 0.17, 5: 0.26 };
const TEAM_TYPE_BONUS: Record<number, number> = { 2: 0.03, 3: 0.06, 4: 0.10, 5: 0.15 };

// 타입/컬렉션별 시너지 "크기" 가중치(정체성). 최종 = base[count] × weight. Swift TeamSynergy 와 1:1.
const TYPE_WEIGHT: Record<BattleType, number> = {
  arcane: 1.25, chaos: 1.15, warrior: 1.10, beast: 1.00, machine: 0.85, mascot: 0.80,
};
// 컬렉션 테마 3티어 S/A/B = 1.20/1.00/0.85. 미등록(=A) 은 1.0.
const COLLECTION_WEIGHT: Record<string, number> = {
  tenXEngineer: 1.20, onCall: 1.20, rustEvangelists: 1.20, tokenBurners: 1.20, ciRunners: 1.20,   // S
  deprecated: 0.85, todoSince2019: 0.85, oomKilled: 0.85, happyPath: 0.85, helloWorld: 0.85, vibeCoders: 0.85,  // B
};
const SYN_WEIGHT_MIN = 0.80, SYN_WEIGHT_MAX = 1.30, SIG_STAT_CAP = 1.55;   // 가드레일(clamp + 대표 스탯 상한)
function clampW(w: number): number { return Math.min(SYN_WEIGHT_MAX, Math.max(SYN_WEIGHT_MIN, w)); }

export type StatKind = "hp" | "atk" | "def" | "spd";
// 각 타입 시너지가 강화하는 대표 스탯(아키타입 성향).
export function signatureStat(type: BattleType): StatKind {
  switch (type) {
    case "beast": return "spd";
    case "warrior": return "atk";
    case "arcane": return "atk";
    case "chaos": return "spd";
    case "machine": return "def";
    case "mascot": return "hp";
  }
}
export interface SynergyBonus { collectionMult: number; typeStat: StatKind | null; typeAdd: number; }

export function teamSynergyBonus(kinds: string[]): SynergyBonus {
  if (kinds.length < 2) return { collectionMult: 1.0, typeStat: null, typeAdd: 0 };
  // 최다 컬렉션 (배열 순서 first-max) → count + 정체성(가중치). tie는 strict > 로 먼저 등장한 것 채택.
  const collCounts = new Map<string, number>();
  for (const k of kinds) { const c = collectionOf(k); collCounts.set(c, (collCounts.get(c) ?? 0) + 1); }
  let topColl: string | null = null, topCollCount = 0;
  for (const k of kinds) {
    const c = collCounts.get(collectionOf(k)) ?? 0;
    if (c > topCollCount) { topCollCount = c; topColl = collectionOf(k); }
  }
  const collW = topColl ? clampW(COLLECTION_WEIGHT[topColl] ?? 1.0) : 1.0;
  const collectionMult = 1.0 + (TEAM_COLLECTION_BONUS[topCollCount] ?? 0) * collW;
  // 최다 타입 (배열 순서 first-max) → count + 정체성. Swift TeamSynergy.bonus 와 1:1.
  const typeCounts = new Map<BattleType, number>();
  for (const k of kinds) { const t = battleTypeOf(k); typeCounts.set(t, (typeCounts.get(t) ?? 0) + 1); }
  let topType: BattleType | null = null, topTypeCount = 0;
  for (const k of kinds) {
    const t = battleTypeOf(k);
    const c = typeCounts.get(t) ?? 0;
    if (c > topTypeCount) { topTypeCount = c; topType = t; }
  }
  const typeW = topType ? clampW(TYPE_WEIGHT[topType] ?? 1.0) : 1.0;
  let typeAdd = (TEAM_TYPE_BONUS[topTypeCount] ?? 0) * typeW;
  typeAdd = Math.max(0, Math.min(typeAdd, SIG_STAT_CAP - collectionMult));   // 대표 스탯 총 시너지 상한
  if (topType && typeAdd > 0) return { collectionMult, typeStat: signatureStat(topType), typeAdd };
  return { collectionMult, typeStat: null, typeAdd: 0 };
}

// 특정 스탯의 최종 시너지 배수.
export function synergyStatMultiplier(b: SynergyBonus, stat: StatKind): number {
  return b.collectionMult + (b.typeStat === stat ? b.typeAdd : 0);
}

// ─────────────────────────────────────────────────────────────────────────────
// 매치·레이팅·보상 정책 (기획 §2-7 / §2-8 / §10)

export const RATING_START = 1000;
export const RATING_K = 24;                 // Elo ±K
export const DAILY_RANK_LIMIT = 10;         // 랭크전 하루 N판
export const WIN_COIN_BASE = 30;            // 승리 기본 코인 (+상성·상위레이팅 보너스는 서버 산정)
export const RANKED_TEAM_SIZE = 5;          // 랭크전 5v5 — 도전자·방어자 모두 이 크기 강제(매칭 대칭)
