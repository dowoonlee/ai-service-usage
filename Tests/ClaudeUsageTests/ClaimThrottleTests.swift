import XCTest
@testable import ClaudeUsage

/// 주기 게이트(`ViewModel.isDue`) 검증 — 보상 claim용 leaderboard fetch가 폴링마다 나가던 것을
/// 1시간 간격으로 좁힌 로직의 회귀 가드. 이 호출은 실측상 Edge Function 호출의 ~35%,
/// Egress의 대부분을 차지했다.
final class ClaimThrottleTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_786_500_000)

    // 첫 호출(기록 없음)은 항상 통과 — 앱을 켜자마자 한 번은 확인한다.
    func testFirstCallIsAlwaysDue() {
        XCTAssertTrue(ViewModel.isDue(lastAt: nil, now: t0, interval: 3600))
    }

    // 간격 이내면 막고, 정확히 간격에 도달하면 통과.
    func testBoundary() {
        XCTAssertFalse(ViewModel.isDue(lastAt: t0, now: t0, interval: 3600))
        XCTAssertFalse(ViewModel.isDue(lastAt: t0, now: t0.addingTimeInterval(3599), interval: 3600))
        XCTAssertTrue(ViewModel.isDue(lastAt: t0, now: t0.addingTimeInterval(3600), interval: 3600))
        XCTAssertTrue(ViewModel.isDue(lastAt: t0, now: t0.addingTimeInterval(7200), interval: 3600))
    }

    // 시계가 뒤로 간 경우(수동 변경·NTP 보정)엔 막는다 — 음수 경과로 폭주하지 않게.
    func testClockSkewBackwardDoesNotFire() {
        XCTAssertFalse(ViewModel.isDue(lastAt: t0, now: t0.addingTimeInterval(-600), interval: 3600))
    }

    // 폴링 한 시간치(600s × 6)에서 leaderboard fetch는 1회만 나가야 한다.
    // 예전엔 cycle마다 나가 6회였다.
    func testHourlyCadenceFiresOncePerPollingHour() {
        var last: Date? = nil
        var fired = 0
        for i in 0..<6 {                                   // 600s 간격 6 cycle = 1시간
            let now = t0.addingTimeInterval(Double(i) * 600)
            if ViewModel.isDue(lastAt: last, now: now, interval: ViewModel.claimLeaderboardIntervalSec) {
                fired += 1
                last = now
            }
        }
        XCTAssertEqual(fired, 1, "첫 cycle에서 1회만 — 나머지는 스로틀에 걸린다")
    }

    // 비활성 루프(30s)에서도 재시도 게이트가 600s 간격을 지킨다.
    func testIdleGateKeepsTenMinuteCadence() {
        var last: Date? = nil
        var fired = 0
        for i in 0..<60 {                                  // 30s × 60 = 30분
            let now = t0.addingTimeInterval(Double(i) * 30)
            if ViewModel.isDue(lastAt: last, now: now, interval: ViewModel.idleClaimCheckIntervalSec) {
                fired += 1
                last = now
            }
        }
        XCTAssertEqual(fired, 3, "30분 동안 600s 간격 → 3회")
    }
}
