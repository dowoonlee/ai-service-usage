import Foundation

// 펫 강화(도박) 순수 로직 (P0) — 메이플/던파식 3단 리스크 계단.
// 설계 SSOT: docs/plans/pet-battle.md §2-9 / §10.
//
// 실제 랭크전에선 서버가 이 로직으로 RNG를 굴리고 결과를 확정한다(daily-quiz 원리).
// 여기 Swift 구현은 (a) 서버 `_shared/enhance_engine.ts`(P1b 이식 예정)와 규칙 1:1을 목표,
// (b) 확률/기대값 UI 표시, (c) 순수 로직 테스트용. `roll`은 주입된 RNG로 결정적 —
// 서버는 crypto RNG, 테스트는 SeededRNG.

/// 결정적 시드 RNG (SplitMix64). 서버-클라 재현·테스트용. 서버는 crypto random 사용.
struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

extension RandomNumberGenerator {
    /// [0, 1) 균등 난수 — 상위 53비트 추출(2^53 분해능). `Double.random(in:using:)`은 Swift
    /// 버전 간 알고리즘 안정성이 보장되지 않고 TS 이식이 까다로워, 서버(`_shared`) 포팅 시
    /// 비트 단위로 동일 재현되도록 명세를 고정한다: `(next() >> 11) / 2^53`.
    mutating func uniform01() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)   // 2^53
    }
}

/// 강화 1회 시도 결과.
enum EnhanceOutcome: String, Codable, Hashable {
    case success    // +1
    case stay       // 변화 없음 (VP만 소모)
    case downgrade  // -1
    case destroy    // 강화 0 리셋 (펫 자체는 불가침)
}

/// 강화 구간 — 3단 리스크 계단.
enum EnhanceZone: String, Codable {
    case safe       // +0~+5: 실패=유지
    case downgrade  // +6~+9: 실패=유지 or 강등
    case destroy    // +10~+14: 실패=유지 or 파괴
}

enum EnhanceEngine {
    static let maxLevel = 15

    /// [succ, stay, down, destroy] — index = 현재 강화 레벨 L(0…14), 시도 +L→+L+1.
    /// 각 행 합 = 1.0. 확률 UI에 투명 공개(연구: 투명성이 몰입 안 깎음 + KR 규범).
    static let odds: [[Double]] = [
        [0.95, 0.05, 0,    0],   // +0→1
        [0.90, 0.10, 0,    0],   // +1→2
        [0.85, 0.15, 0,    0],   // +2→3
        [0.78, 0.22, 0,    0],   // +3→4
        [0.68, 0.32, 0,    0],   // +4→5
        [0.60, 0.40, 0,    0],   // +5→6   (안전 구간 끝)
        [0.50, 0.38, 0.12, 0],   // +6→7   (하락 시작)
        [0.42, 0.42, 0.16, 0],   // +7→8
        [0.35, 0.45, 0.20, 0],   // +8→9
        [0.30, 0.48, 0.22, 0],   // +9→10
        [0.22, 0.60, 0,    0.18], // +10→11 (파괴 시작)
        [0.18, 0.62, 0,    0.20], // +11→12
        [0.13, 0.65, 0,    0.22], // +12→13
        [0.09, 0.68, 0,    0.23], // +13→14
        [0.06, 0.69, 0,    0.25], // +14→15
    ]

    /// 시도당 VP 비용 — 지수 폭증(메이플 ^2.7 곡선). index = 현재 레벨 L(0…14).
    static let vpCost: [Int] =
        [20, 40, 75, 130, 210, 320, 470, 680, 950, 1300, 1800, 2500, 3400, 4600, 6200]

    static func zone(level: Int) -> EnhanceZone {
        if level <= 5 { return .safe }
        if level <= 9 { return .downgrade }
        return .destroy
    }

    /// 시도 가능 여부 (만렙 미만).
    static func canEnhance(level: Int) -> Bool { level >= 0 && level < maxLevel }

    /// 기본(Common 기준) 시도 VP 비용.
    static func cost(level: Int) -> Int {
        vpCost[min(max(0, level), vpCost.count - 1)]
    }

    /// 희귀도별 강화 비용 배수 — 고등급일수록 스탯이 세니 강화도 비싸다. (튜닝 대상)
    static func rarityCostMultiplier(_ rarity: Rarity) -> Double {
        switch rarity {
        case .common:    return 1.0
        case .rare:      return 1.4
        case .epic:      return 2.0
        case .legendary: return 3.0
        case .mythic:    return 4.5
        }
    }

    /// 희귀도 반영 시도 VP 비용.
    static func cost(level: Int, rarity: Rarity) -> Int {
        Int((Double(cost(level: level)) * rarityCostMultiplier(rarity)).rounded())
    }

    // MARK: 안전 강화 모드 (완화장치) — 파괴 없음 + soft-pity. 재원: VP 더 비쌈.
    static let safeMaxLevel = 11        // 안전 강화는 +11→+12 까지(level ≤ 11). 이후는 일반(도박)만.
    static let safeVpMultiplier = 1.5   // 안전 강화 VP 할증.
    static let pityStep = 0.02          // 연속 실패 1회당 성공률 보정.
    static let pityCap  = 0.20          // soft-pity 상한.

    /// 안전 강화 가능 레벨.
    static func canSafeEnhance(level: Int) -> Bool { level >= 0 && level <= safeMaxLevel }

    /// 안전 강화 확률행 — 파괴→유지 이동 + soft-pity(연속 실패 보정). 합 = 1.
    static func safeOdds(level: Int, failStreak: Int) -> [Double] {
        var o = odds[min(max(0, level), odds.count - 1)]
        o[1] += o[3]; o[3] = 0                                    // 파괴 → 유지(파괴 없음)
        let boost = min(pityCap, Double(max(0, failStreak)) * pityStep)
        let applied = min(boost, o[1])                            // 유지에서 성공으로 이전
        o[0] += applied; o[1] -= applied
        return o
    }

    /// 안전 강화 시도 VP 비용(할증).
    static func safeCost(level: Int, rarity: Rarity) -> Int {
        Int((Double(cost(level: level, rarity: rarity)) * safeVpMultiplier).rounded())
    }

    /// 확률행에 따라 결과를 굴린다. 주입 RNG로 결정적.
    private static func rollRow<G: RandomNumberGenerator>(_ o: [Double], using rng: inout G) -> EnhanceOutcome {
        let r = rng.uniform01()
        if r < o[0] { return .success }
        if r < o[0] + o[1] { return .stay }
        if o[2] > 0, r < o[0] + o[1] + o[2] { return .downgrade }
        return o[3] > 0 ? .destroy : .stay
    }

    /// 일반(도박) 강화 굴림.
    static func roll<G: RandomNumberGenerator>(level: Int, using rng: inout G) -> EnhanceOutcome {
        rollRow(odds[min(max(0, level), odds.count - 1)], using: &rng)
    }

    /// 안전 강화 굴림 — 파괴 없음 + soft-pity.
    static func rollSafe<G: RandomNumberGenerator>(level: Int, failStreak: Int, using rng: inout G) -> EnhanceOutcome {
        rollRow(safeOdds(level: level, failStreak: failStreak), using: &rng)
    }

    /// 결과를 현재 레벨에 적용.
    static func apply(level: Int, outcome: EnhanceOutcome) -> Int {
        switch outcome {
        case .success:   return min(maxLevel, level + 1)
        case .stay:      return level
        case .downgrade: return max(0, level - 1)
        case .destroy:   return 0
        }
    }

    /// +0에서 목표 레벨 도달까지의 기대 VP (파괴 리셋·강등 반영, 마르코프 흡수 체인).
    /// 파괴→0, 강등→-1을 포함해 재도전 비용이 하위 단계까지 다시 쌓이는 것을 반영.
    /// (아티팩트 강화 곡선과 동일: +15 ≈ 5.3M, +1 = 21)
    static func expectedVP(toReach target: Int) -> Double {
        let t = min(max(1, target), maxLevel)
        var T = [Double](repeating: 0, count: t + 1)   // T[t] = 0
        // Gauss-Seidel 반복 — destroy가 T[0]을 참조하는 자기참조라 수렴할 때까지.
        for _ in 0..<4000 {
            for i in stride(from: t - 1, through: 0, by: -1) {
                let o = odds[i]
                let num = Double(vpCost[i])
                    + o[0] * T[i + 1]
                    + o[2] * (i > 0 ? T[i - 1] : T[0])
                    + o[3] * T[0]
                T[i] = num / (1 - o[1])
            }
        }
        return T[0]
    }
}
