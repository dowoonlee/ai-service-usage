import XCTest
@testable import ClaudeUsage

final class ProjectionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let fiveHour: TimeInterval = 5 * 3600
    private let sevenDay: TimeInterval = 7 * 86_400

    // 5h 창: 1시간 경과 시 20% → 100% 도달 예상.
    func testProjectedPctLinearExtrapolation() {
        let resetAt = now.addingTimeInterval(4 * 3600)   // 1h 경과
        let pct = ViewModel.projectedPct(current: 20.0, resetAt: resetAt, periodLength: fiveHour, now: now)
        XCTAssertNotNil(pct)
        XCTAssertEqual(pct!, 100.0, accuracy: 0.01)
    }

    // 5h 창에서 15분 미만 경과면 nil (노이즈 방지).
    func testProjectedPctNilWhenTooEarly() {
        let resetAt = now.addingTimeInterval(fiveHour - 60)   // 1분 경과
        let pct = ViewModel.projectedPct(current: 5.0, resetAt: resetAt, periodLength: fiveHour, now: now)
        XCTAssertNil(pct)
    }

    // 7d 창에서 5% 경과 미만이면 nil.
    func testProjectedPctNilWhenUnder5PercentElapsed() {
        let elapsed: TimeInterval = sevenDay * 0.04
        let resetAt = now.addingTimeInterval(sevenDay - elapsed)
        let pct = ViewModel.projectedPct(current: 1.0, resetAt: resetAt, periodLength: sevenDay, now: now)
        XCTAssertNil(pct)
    }

    // current/resetAt 중 하나라도 nil이면 nil.
    func testProjectedPctNilOnMissingInput() {
        let resetAt = now.addingTimeInterval(3600)
        XCTAssertNil(ViewModel.projectedPct(current: nil, resetAt: resetAt, periodLength: fiveHour, now: now))
        XCTAssertNil(ViewModel.projectedPct(current: 50.0, resetAt: nil, periodLength: fiveHour, now: now))
    }

    // 페이스가 100% 넘으면 reset 이전 시점에 exhaustion 반환.
    func testProjectedExhaustionWhenOverpace() {
        let resetAt = now.addingTimeInterval(4 * 3600)   // 1h 경과
        let exhaust = ViewModel.projectedExhaustionDate(current: 30.0, resetAt: resetAt, periodLength: fiveHour, now: now)
        XCTAssertNotNil(exhaust)
        // 30%/1h = 30%/h → 70% 더 가려면 70/30 h ≈ 2.333h
        let expected = now.addingTimeInterval(70.0 / 30.0 * 3600)
        XCTAssertEqual(exhaust!.timeIntervalSinceReferenceDate, expected.timeIntervalSinceReferenceDate, accuracy: 1.0)
    }

    // 페이스가 100% 안 닿으면 nil (resetAt 이후 도달 → 의미 없음).
    func testProjectedExhaustionNilWhenUnderpace() {
        let resetAt = now.addingTimeInterval(4 * 3600)   // 1h 경과
        let exhaust = ViewModel.projectedExhaustionDate(current: 5.0, resetAt: resetAt, periodLength: fiveHour, now: now)
        XCTAssertNil(exhaust)
    }
}
