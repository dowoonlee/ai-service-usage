import XCTest
@testable import ClaudeUsage

final class BackoffTests: XCTestCase {
    // 짧은 sleep(<60s)은 jitter 통과 — reset 직전 단축 보호.
    func testJitterPassthroughForShortSleep() {
        XCTAssertEqual(ViewModel.applyJitter(30), 30)
        XCTAssertEqual(ViewModel.applyJitter(60), 60)
    }

    // 긴 sleep은 ±15% 범위로 무작위. 100회 샘플로 범위 검증.
    func testJitterWithin15PercentRange() {
        let base: TimeInterval = 600
        for _ in 0..<100 {
            let result = ViewModel.applyJitter(base)
            XCTAssertGreaterThanOrEqual(result, base * 0.85)
            XCTAssertLessThanOrEqual(result, base * 1.15)
        }
    }

    // backoff multiplier: 0..4 정상, 음수/큰값 모두 0..4로 clamp.
    func testBackoffMultiplierClamp() {
        XCTAssertEqual(ViewModel.backoffMultiplier(steps: 0), 1.0)
        XCTAssertEqual(ViewModel.backoffMultiplier(steps: 1), 2.0)
        XCTAssertEqual(ViewModel.backoffMultiplier(steps: 2), 4.0)
        XCTAssertEqual(ViewModel.backoffMultiplier(steps: 3), 8.0)
        XCTAssertEqual(ViewModel.backoffMultiplier(steps: 4), 16.0)
        XCTAssertEqual(ViewModel.backoffMultiplier(steps: 100), 16.0)
        XCTAssertEqual(ViewModel.backoffMultiplier(steps: -5), 1.0)
    }
}
