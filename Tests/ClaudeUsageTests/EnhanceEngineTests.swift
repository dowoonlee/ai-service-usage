import XCTest
@testable import ClaudeUsage

/// 강화(도박) 순수 로직 검증 (P0) — 3단 리스크 계단·파괴 리셋·확률·기대값.
final class EnhanceEngineTests: XCTestCase {

    // 각 레벨 확률행 합 = 1.0.
    func testOddsSumToOne() {
        for (i, row) in EnhanceEngine.odds.enumerated() {
            XCTAssertEqual(row.reduce(0, +), 1.0, accuracy: 1e-9, "레벨 \(i) 확률합 ≠ 1")
        }
        XCTAssertEqual(EnhanceEngine.odds.count, 15)      // +0…+14 시도
        XCTAssertEqual(EnhanceEngine.vpCost.count, 15)
    }

    // 3단 리스크 계단 구조: 안전(0~5) 무손실, 하락(6~9) 강등만, 파괴(10~14) 파괴만.
    func testRiskZones() {
        for L in 0...14 {
            let o = EnhanceEngine.odds[L]
            let down = o[2], destroy = o[3]
            switch EnhanceEngine.zone(level: L) {
            case .safe:
                XCTAssertEqual(down, 0); XCTAssertEqual(destroy, 0)
                XCTAssertTrue((0...5).contains(L))
            case .downgrade:
                XCTAssertGreaterThan(down, 0); XCTAssertEqual(destroy, 0)
                XCTAssertTrue((6...9).contains(L))
            case .destroy:
                XCTAssertEqual(down, 0); XCTAssertGreaterThan(destroy, 0)
                XCTAssertTrue((10...14).contains(L))
            }
        }
    }

    // 결과 적용: 성공 +1(만렙 캡), 유지 불변, 강등 -1(0 하한), 파괴 → 0.
    func testApplyOutcome() {
        XCTAssertEqual(EnhanceEngine.apply(level: 7, outcome: .success), 8)
        XCTAssertEqual(EnhanceEngine.apply(level: 15, outcome: .success), 15, "만렙 초과 없음")
        XCTAssertEqual(EnhanceEngine.apply(level: 7, outcome: .stay), 7)
        XCTAssertEqual(EnhanceEngine.apply(level: 7, outcome: .downgrade), 6)
        XCTAssertEqual(EnhanceEngine.apply(level: 0, outcome: .downgrade), 0, "0 하한")
        XCTAssertEqual(EnhanceEngine.apply(level: 14, outcome: .destroy), 0, "파괴 = 강화 리셋")
    }

    func testCanEnhanceAndCost() {
        XCTAssertTrue(EnhanceEngine.canEnhance(level: 0))
        XCTAssertTrue(EnhanceEngine.canEnhance(level: 14))
        XCTAssertFalse(EnhanceEngine.canEnhance(level: 15), "만렙은 시도 불가")
        // 비용 단조 증가.
        for i in 1..<EnhanceEngine.vpCost.count {
            XCTAssertGreaterThan(EnhanceEngine.vpCost[i], EnhanceEngine.vpCost[i-1])
        }
    }

    // 희귀도별 강화 비용 차등 — 고등급일수록 비쌈.
    func testRarityCostTiers() {
        XCTAssertEqual(EnhanceEngine.rarityCostMultiplier(.common), 1.0, accuracy: 1e-9)
        let order: [Rarity] = [.common, .rare, .epic, .legendary, .mythic]
        for i in 1..<order.count {
            XCTAssertGreaterThan(EnhanceEngine.rarityCostMultiplier(order[i]),
                                 EnhanceEngine.rarityCostMultiplier(order[i - 1]))
        }
        // Common은 base와 동일, 고등급은 더 비쌈.
        XCTAssertEqual(EnhanceEngine.cost(level: 11, rarity: .common), EnhanceEngine.cost(level: 11))
        XCTAssertGreaterThan(EnhanceEngine.cost(level: 11, rarity: .mythic),
                             EnhanceEngine.cost(level: 11, rarity: .common))
    }

    // 시드 고정 시 결과 시퀀스 결정적(서버 RNG 재현성).
    func testRollDeterministicWithSeed() {
        func sequence(seed: UInt64) -> [EnhanceOutcome] {
            var rng = SeededRNG(seed: seed)
            return (0..<50).map { _ in EnhanceEngine.roll(level: 11, using: &rng) }
        }
        XCTAssertEqual(sequence(seed: 42), sequence(seed: 42))
        XCTAssertNotEqual(sequence(seed: 42), sequence(seed: 43))
    }

    // roll이 확률표를 실제로 따르는지 (통계적 — 대량 표본, 넉넉한 허용오차).
    func testRollFollowsProbabilities() {
        let level = 11   // 성공 18% / 유지 62% / 파괴 20%
        let n = 40_000
        var succ = 0, destroy = 0
        for i in 0..<n {
            var rng = SeededRNG(seed: UInt64(i) &* 2_654_435_761 &+ 1)
            switch EnhanceEngine.roll(level: level, using: &rng) {
            case .success: succ += 1
            case .destroy: destroy += 1
            default: break
            }
        }
        let pSucc = Double(succ) / Double(n)
        let pDestroy = Double(destroy) / Double(n)
        XCTAssertEqual(pSucc, 0.18, accuracy: 0.02)
        XCTAssertEqual(pDestroy, 0.20, accuracy: 0.02)
    }

    // 마르코프 기대 VP — 파괴 리셋 반영. 아티팩트 곡선 회귀 가드.
    func testExpectedVP() {
        XCTAssertEqual(EnhanceEngine.expectedVP(toReach: 1), 20, accuracy: 3, "+1은 안전(성공95%)이라 ≈비용")
        let e15 = EnhanceEngine.expectedVP(toReach: 15)
        XCTAssertGreaterThan(e15, 5_000_000, "파괴 리셋으로 +15 기대 VP는 수백만")
        XCTAssertLessThan(e15, 5_600_000)
        // 단조 증가.
        var prev = 0.0
        for t in 1...15 {
            let e = EnhanceEngine.expectedVP(toReach: t)
            XCTAssertGreaterThan(e, prev)
            prev = e
        }
    }
}
