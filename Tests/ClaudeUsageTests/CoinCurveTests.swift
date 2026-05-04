import XCTest
@testable import ClaudeUsage

final class CoinCurveTests: XCTestCase {
    // 양 끝단(0%, 100%) 고정 — 사용자 결정의 핵심 invariant.
    func testCurveEndpoints() {
        XCTAssertEqual(CoinLedger.curve(0), 0, accuracy: 1e-9)
        XCTAssertEqual(CoinLedger.curve(1), 1, accuracy: 1e-9)
    }

    // 0~1 범위 밖은 clamp.
    func testCurveClamping() {
        XCTAssertEqual(CoinLedger.curve(-0.5), 0)
        XCTAssertEqual(CoinLedger.curve(2.0), 1)
    }

    // concave: 모든 0<x<1에서 curve(x) > x. 즉 linear 대비 위에 위치.
    func testCurveIsConcave() {
        for x in stride(from: 0.05, through: 0.95, by: 0.05) {
            XCTAssertGreaterThan(CoinLedger.curve(x), x,
                                 "curve(\(x)) should exceed linear at midpoints")
        }
    }

    // sqrt 기반 — 알려진 값 몇 개 점검.
    func testCurveKnownValues() {
        XCTAssertEqual(CoinLedger.curve(0.25), 0.5,   accuracy: 1e-9)
        XCTAssertEqual(CoinLedger.curve(0.5),  0.7071, accuracy: 1e-3)
        XCTAssertEqual(CoinLedger.curve(0.81), 0.9,   accuracy: 1e-9)
    }

    // 0→100% 누적 적립 합계가 max coin과 같아야 — 양 끝 고정 invariant의 누적 검증.
    // 폴링 시뮬레이션: 0→10→25→50→75→90→100%로 들어와도 합산은 50.
    func testFiveHourTotalEqualsMax() {
        let pcts: [Double] = [0, 10, 25, 50, 75, 90, 100]
        var total: Double = 0
        for i in 1..<pcts.count {
            let prev = CoinLedger.curve(pcts[i - 1] / 100.0) * CoinLedger.claudeFiveHourMaxCoin
            let curr = CoinLedger.curve(pcts[i]     / 100.0) * CoinLedger.claudeFiveHourMaxCoin
            total += (curr - prev)
        }
        XCTAssertEqual(total, CoinLedger.claudeFiveHourMaxCoin, accuracy: 1e-9)
    }

    // 7d 윈도우도 같은 invariant.
    func testSevenDayTotalEqualsMax() {
        let prev = CoinLedger.curve(0) * CoinLedger.claudeSevenDayMaxCoin
        let curr = CoinLedger.curve(1) * CoinLedger.claudeSevenDayMaxCoin
        XCTAssertEqual(curr - prev, CoinLedger.claudeSevenDayMaxCoin, accuracy: 1e-9)
    }

    // Plan multiplier 매핑 — 명시 케이스 + 기본값.
    func testPlanMultiplierMapping() {
        XCTAssertEqual(CoinLedger.planMultiplier("Free"),       0.5)
        XCTAssertEqual(CoinLedger.planMultiplier("Pro"),        1.0)
        XCTAssertEqual(CoinLedger.planMultiplier("Max"),        2.0)
        XCTAssertEqual(CoinLedger.planMultiplier("Max 5x"),     2.0)
        XCTAssertEqual(CoinLedger.planMultiplier("Max 20x"),    4.0)
        XCTAssertEqual(CoinLedger.planMultiplier("Team"),       1.0)
        XCTAssertEqual(CoinLedger.planMultiplier("Enterprise"), 1.5)
        XCTAssertEqual(CoinLedger.planMultiplier(nil),          1.0)
        XCTAssertEqual(CoinLedger.planMultiplier("unknown"),    1.0)
    }

    // 대소문자/공백 변형도 정상 매칭.
    func testPlanMultiplierCaseInsensitive() {
        XCTAssertEqual(CoinLedger.planMultiplier("MAX 20x"), 4.0)
        XCTAssertEqual(CoinLedger.planMultiplier("max 5x"),  2.0)
        XCTAssertEqual(CoinLedger.planMultiplier("PRO"),     1.0)
    }

    // Plan multiplier가 양 끝 invariant를 깨지 않는지 — Max 20x가 100% 채울 때 200 coin.
    func testFiveHourTotalWithPlanMultiplier() {
        let multipliers: [(String, Double)] = [
            ("Pro",     50),
            ("Max",     100),
            ("Max 20x", 200),
            ("Free",    25),
        ]
        for (plan, expected) in multipliers {
            let m = CoinLedger.planMultiplier(plan)
            let total = (CoinLedger.curve(1.0) - CoinLedger.curve(0.0))
                * CoinLedger.claudeFiveHourMaxCoin * m
            XCTAssertEqual(total, expected, accuracy: 1e-9, "plan=\(plan)")
        }
    }
}
