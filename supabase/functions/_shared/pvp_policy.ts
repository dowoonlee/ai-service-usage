// 아레나(PvP) 정책 상수 + 스탯 파생 + 펫간 상성 — 서버 authoritative SSOT.
//
// Swift `PetBattleStats.swift` / `PetSynergy.swift` 와 값·규칙 1:1. 동일 입력 → 동일 스탯/상성.
// 배틀·강화 엔진(`battle_engine.ts` / `enhance_engine.ts`)이 이 모듈을 참조한다.
// 펫별 rarity/collection 은 클라 하드코딩이라 서버엔 없어 `pet_meta_gen.ts`(Swift 생성)로 포팅.
//
// 반올림 규약: Swift `Int(x.rounded())` = round-half-away-from-zero. 입력이 전부 양수라 JS
// `Math.round`와 동일하지만, 명세 고정을 위해 `roundAway`를 쓴다(음수 안전).

import { RARITY, COLLECTION } from "./pet_meta_gen.ts";

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
export const TYPE_SUPER = 1.6;
export const TYPE_WEAK = 0.625;   // = 1 / 1.6
export function effectiveness(attacker: BattleType, defender: BattleType): number {
  if (BEATS[attacker] === defender) return TYPE_SUPER;
  if (BEATS[defender] === attacker) return TYPE_WEAK;
  return 1.0;
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
export const VARIANT_BONUS = [0, 0.02, 0.04, 0.06, 0.10];   // 기본/이로치1·2·3/레인보우
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

export function computeStats(
  kind: string, variant: number, enhanceLevel: number, progressUnits: number,
): BattleStats {
  const base = RARITY_BASE[rarityOf(kind)];
  const a = ARCHETYPE[battleTypeOf(kind)];
  const growth = growthMultiplier(enhanceLevel, progressUnits);
  const vb = 1.0 + variantMultiplier(variant);
  const stat = (arch: number) => Math.max(1, roundAway(base * arch * growth * vb));
  return { hp: stat(a[0]), atk: stat(a[1]), def: stat(a[2]), spd: stat(a[3]) };
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
  const counts = (vals: string[]) => {
    const m = new Map<string, number>();
    for (const v of vals) m.set(v, (m.get(v) ?? 0) + 1);
    return m;
  };
  const maxColl = Math.max(...counts(kinds.map(collectionOf)).values());
  const collectionMult = 1.0 + (TEAM_COLLECTION_BONUS[maxColl] ?? 0);
  // 최다 타입 그룹 → 그 타입 대표 스탯 강화. tie(5마리 2+2+1 등)는 아래 strict > 로 팀 순서
  // 먼저 등장한 타입 채택 — 결정적, Swift TeamSynergy.bonus 와 1:1.
  let topType: BattleType | null = null, topCount = 0;
  for (const [t, c] of counts(kinds.map(battleTypeOf))) {
    if (c > topCount) { topCount = c; topType = t as BattleType; }
  }
  const add = TEAM_TYPE_BONUS[topCount] ?? 0;
  if (topType && add > 0) return { collectionMult, typeStat: signatureStat(topType), typeAdd: add };
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
