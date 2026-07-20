// 펫 강화(도박) 순수 로직 — 서버 authoritative RNG. Swift `EnhanceEngine.swift` 와 규칙 1:1.
//
// 실제 랭크전에선 `pet-enhance` Edge Function 이 이 로직으로 RNG를 굴려 결과를 확정한다.
// `roll` 은 주입된 RNG로 결정적: 서버는 crypto 시드로 SeededRNG를 만들고, 테스트/파리티는 고정 시드.

// ── 결정적 시드 RNG (SplitMix64). Swift SeededRNG 와 비트 일치.
// UInt64 wrapping(&+, &*)을 BigInt + 64비트 마스크로 재현. uniform01 = (next()>>11)/2^53.
const MASK64 = (1n << 64n) - 1n;
const GOLD = 0x9E3779B97F4A7C15n;
const MUL1 = 0xBF58476D1CE4E5B9n;
const MUL2 = 0x94D049BB133111EBn;

export class SeededRNG {
  private state: bigint;
  constructor(seed: bigint) { this.state = seed === 0n ? GOLD : (seed & MASK64); }
  next(): bigint {
    this.state = (this.state + GOLD) & MASK64;
    let z = this.state;
    z = ((z ^ (z >> 30n)) * MUL1) & MASK64;
    z = ((z ^ (z >> 27n)) * MUL2) & MASK64;
    return (z ^ (z >> 31n)) & MASK64;
  }
  // [0, 1) 균등 — 상위 53비트. Swift `RandomNumberGenerator.uniform01()` 와 비트 일치.
  uniform01(): number {
    return Number(this.next() >> 11n) * (1 / 9007199254740992); // 2^53
  }
}

export type EnhanceOutcome = "success" | "stay" | "downgrade" | "destroy";
export type EnhanceZone = "safe" | "downgrade" | "destroy";

export const MAX_LEVEL = 15;

// [succ, stay, down, destroy] — index = 현재 레벨 L(0…14), 시도 +L→+L+1. 각 행 합 = 1.0.
export const ODDS: number[][] = [
  [0.95, 0.05, 0, 0],   // +0→1
  [0.90, 0.10, 0, 0],   // +1→2
  [0.85, 0.15, 0, 0],   // +2→3
  [0.78, 0.22, 0, 0],   // +3→4
  [0.68, 0.32, 0, 0],   // +4→5
  [0.60, 0.40, 0, 0],   // +5→6   (안전 끝)
  [0.50, 0.38, 0.12, 0], // +6→7   (하락 시작)
  [0.42, 0.42, 0.16, 0], // +7→8
  [0.35, 0.45, 0.20, 0], // +8→9
  [0.30, 0.48, 0.22, 0], // +9→10
  [0.22, 0.60, 0, 0.18], // +10→11 (파괴 시작)
  [0.18, 0.62, 0, 0.20], // +11→12
  [0.13, 0.65, 0, 0.22], // +12→13
  [0.09, 0.68, 0, 0.23], // +13→14
  [0.06, 0.69, 0, 0.25], // +14→15
];

// 시도당 기본(Common) VP 비용 — 지수 폭증. index = 현재 레벨 L(0…14).
export const VP_COST = [20, 40, 75, 130, 210, 320, 470, 680, 950, 1300, 1800, 2500, 3400, 4600, 6200];

// 희귀도별 강화 비용 배수.
const RARITY_COST_MULT: Record<string, number> = {
  common: 1.0, rare: 1.4, epic: 2.0, legendary: 3.0, mythic: 4.5,
};

export function zone(level: number): EnhanceZone {
  if (level <= 5) return "safe";
  if (level <= 9) return "downgrade";
  return "destroy";
}
export function canEnhance(level: number): boolean {
  return level >= 0 && level < MAX_LEVEL;
}
export function baseCost(level: number): number {
  return VP_COST[Math.min(Math.max(0, level), VP_COST.length - 1)];
}
export function rarityCostMultiplier(rarity: string): number {
  return RARITY_COST_MULT[rarity] ?? 1.0;
}
export function cost(level: number, rarity: string): number {
  return Math.round(baseCost(level) * rarityCostMultiplier(rarity));
}

// 안전 강화 모드 — 파괴 없음 + soft-pity. Swift EnhanceEngine 1:1.
export const SAFE_MAX_LEVEL = 11;
export const SAFE_VP_MULTIPLIER = 1.5;
export const PITY_STEP = 0.02;
export const PITY_CAP = 0.20;

export function canSafeEnhance(level: number): boolean {
  return level >= 0 && level <= SAFE_MAX_LEVEL;
}

// 완화 아이템 VP 가격 (T5 슬라이스 2). 확정권은 도박 우회라 비싸게.
export const PROTECT_PRICE_VP = 400;      // 강화 보호권 — 1회 파괴 방지
export const GUARANTEE_PRICE_VP = 6000;   // 확정 강화권 — 확정 +1
export function safeOdds(level: number, failStreak: number): number[] {
  const o = [...ODDS[Math.min(Math.max(0, level), ODDS.length - 1)]];
  o[1] += o[3]; o[3] = 0;                                  // 파괴 → 유지
  const boost = Math.min(PITY_CAP, Math.max(0, failStreak) * PITY_STEP);
  const applied = Math.min(boost, o[1]);
  o[0] += applied; o[1] -= applied;
  return o;
}
export function safeCost(level: number, rarity: string): number {
  return Math.round(cost(level, rarity) * SAFE_VP_MULTIPLIER);
}

// 확률행에 따라 굴린다. 주입 RNG로 결정적. (Swift rollRow 과 draw 소비 1회 동일.)
function rollRow(o: number[], rng: SeededRNG): EnhanceOutcome {
  const r = rng.uniform01();
  if (r < o[0]) return "success";
  if (r < o[0] + o[1]) return "stay";
  if (o[2] > 0 && r < o[0] + o[1] + o[2]) return "downgrade";
  return o[3] > 0 ? "destroy" : "stay";
}
export function roll(level: number, rng: SeededRNG): EnhanceOutcome {
  return rollRow(ODDS[Math.min(Math.max(0, level), ODDS.length - 1)], rng);
}
export function rollSafe(level: number, failStreak: number, rng: SeededRNG): EnhanceOutcome {
  return rollRow(safeOdds(level, failStreak), rng);
}

export function apply(level: number, outcome: EnhanceOutcome): number {
  switch (outcome) {
    case "success": return Math.min(MAX_LEVEL, level + 1);
    case "stay": return level;
    case "downgrade": return Math.max(0, level - 1);
    case "destroy": return 0;
  }
}

// +0에서 목표 레벨 도달 기대 VP (파괴 리셋·강등 반영, Gauss-Seidel 흡수체인). Swift expectedVP 와 동일.
export function expectedVP(target: number): number {
  const t = Math.min(Math.max(1, target), MAX_LEVEL);
  const T = new Array(t + 1).fill(0);
  for (let iter = 0; iter < 4000; iter++) {
    for (let i = t - 1; i >= 0; i--) {
      const o = ODDS[i];
      const num = VP_COST[i]
        + o[0] * T[i + 1]
        + o[2] * (i > 0 ? T[i - 1] : T[0])
        + o[3] * T[0];
      T[i] = num / (1 - o[1]);
    }
  }
  return T[0];
}
