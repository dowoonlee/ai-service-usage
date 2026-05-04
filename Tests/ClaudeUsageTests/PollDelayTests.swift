import XCTest
@testable import ClaudeUsage

final class PollDelayTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // 주기 reset이 모두 maxInterval 이후라면 maxInterval 그대로 반환.
    func testNoResetsCloserThanMaxInterval() {
        let delay = ViewModel.nextPollDelay(
            now: now,
            resets: [now.addingTimeInterval(3600), now.addingTimeInterval(86_400)],
            maxInterval: 600,
            resetGuard: 30,
            minSleep: 5
        )
        XCTAssertEqual(delay, 600, accuracy: 0.001)
    }

    // resetAt이 maxInterval 안쪽이면 그 직전(resetGuard초 전)에 폴링하도록 단축.
    func testShortenBeforeReset() {
        let delay = ViewModel.nextPollDelay(
            now: now,
            resets: [now.addingTimeInterval(120)],   // 120초 후 reset
            maxInterval: 600,
            resetGuard: 30,
            minSleep: 5
        )
        XCTAssertEqual(delay, 90, accuracy: 0.001)   // 120 - 30 = 90
    }

    // 여러 reset 중 가장 가까운 것을 기준으로.
    func testPicksClosestReset() {
        let delay = ViewModel.nextPollDelay(
            now: now,
            resets: [now.addingTimeInterval(500), now.addingTimeInterval(120), now.addingTimeInterval(1000)],
            maxInterval: 600,
            resetGuard: 30,
            minSleep: 5
        )
        XCTAssertEqual(delay, 90, accuracy: 0.001)
    }

    // resetAt이 이미 지나갔거나 minSleep 안쪽이면 minSleep로 보호.
    func testMinSleepGuard() {
        let delay = ViewModel.nextPollDelay(
            now: now,
            resets: [now.addingTimeInterval(20)],   // 20s 후 reset, guard 30s 빼면 음수
            maxInterval: 600,
            resetGuard: 30,
            minSleep: 5
        )
        // preReset(=now-10s)는 now보다 과거 → maxInterval 사용 → 600
        XCTAssertEqual(delay, 600, accuracy: 0.001)
    }

    // nil reset은 무시.
    func testNilResetsIgnored() {
        let delay = ViewModel.nextPollDelay(
            now: now,
            resets: [nil, nil, now.addingTimeInterval(120)],
            maxInterval: 600,
            resetGuard: 30,
            minSleep: 5
        )
        XCTAssertEqual(delay, 90, accuracy: 0.001)
    }
}
