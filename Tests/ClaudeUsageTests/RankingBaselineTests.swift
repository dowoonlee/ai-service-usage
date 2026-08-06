import XCTest
@testable import ClaudeUsage

/// 복구 후 "제출 단위" 정합 검증 (#197).
/// 제출 delta = submittableTotal - lastSubmittedTotal 이므로, 복구 직후엔 항상 0이 되어야 하고
/// 이후로는 로컬 VP 증가분과 정확히 일치해야 한다.
final class RankingBaselineTests: XCTestCase {

    private func submittable(vp: Int, baseline: Int) -> Int {
        Settings.submittableTotal(vp: vp, baseline: baseline, usesZeroBaseline: true)
    }

    // 새 디바이스 복구(로컬 VP=0, 서버 누적 4099) — baseline 음수로 역산되어 delta=0에서 재개.
    func testRebaseOnFreshDeviceResumesAtZeroDelta() {
        let serverTotal = 4099
        let baseline = Settings.rebasedRankingBaseline(localVP: 0, serverTotal: serverTotal)
        XCTAssertEqual(baseline, -4099)
        XCTAssertEqual(submittable(vp: 0, baseline: baseline) - serverTotal, 0)
    }

    // 복구 후 적립분은 서버 누적 위에 정확히 이어 쌓인다 (과거분 이중 제출 없음).
    func testRebasedDeviceSubmitsOnlyNewGains() {
        let serverTotal = 4099
        let baseline = Settings.rebasedRankingBaseline(localVP: 0, serverTotal: serverTotal)
        let delta = submittable(vp: 120, baseline: baseline) - serverTotal
        XCTAssertEqual(delta, 120)
    }

    // 같은 디바이스 복구(로컬 VP > 서버 누적)도 delta=0에서 재개 — 차액 소급 제출 없음.
    func testRebaseWhenLocalVPExceedsServerTotal() {
        let serverTotal = 4099
        let baseline = Settings.rebasedRankingBaseline(localVP: 5000, serverTotal: serverTotal)
        XCTAssertEqual(baseline, 901)
        XCTAssertEqual(submittable(vp: 5000, baseline: baseline) - serverTotal, 0)
        XCTAssertEqual(submittable(vp: 5050, baseline: baseline) - serverTotal, 50)
    }

    // 회귀 방어: 레거시(절대 누적) 모드를 유지한 채 복구하면 delta가 영구 음수가 된다.
    // 이게 제출이 멈추던 원인이며, 리베이스가 이를 0으로 되돌린다.
    func testLegacyAbsoluteModeStallsAndRebaseRecoversIt() {
        let serverTotal = 4099
        let stalled = Settings.submittableTotal(vp: 0, baseline: 0, usesZeroBaseline: false)
        XCTAssertLessThan(stalled - serverTotal, 0)

        // 리베이스 후 — 로컬 VP가 계속 늘어도 delta는 증가분과 일치.
        let baseline = Settings.rebasedRankingBaseline(localVP: 0, serverTotal: serverTotal)
        XCTAssertEqual(submittable(vp: 0, baseline: baseline) - serverTotal, 0)
        XCTAssertEqual(submittable(vp: 37, baseline: baseline) - serverTotal, 37)
    }

    // zeroBaseline 계정(신규 등록자)은 기존 동작 그대로 — 옵트인 시점 이후 증가분만 제출.
    func testZeroBaselineAccountUnchanged() {
        XCTAssertEqual(Settings.submittableTotal(vp: 1000, baseline: 800, usesZeroBaseline: true), 200)
        // baseline보다 VP가 작아도 음수로 새지 않는다.
        XCTAssertEqual(Settings.submittableTotal(vp: 700, baseline: 800, usesZeroBaseline: true), 0)
    }
}
