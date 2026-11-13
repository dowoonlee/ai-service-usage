import XCTest
@testable import ClaudeUsage

/// 길드 기여 지표 적립 규칙 — 같은 달 증가분 / 달 바뀜 전체 / 첫 동기화 / 경계 유예 / 기준선 불후퇴.
final class GuildContributionTrackerTests: SandboxedTestCase {
    private typealias T = GuildContributionTracker

    /// Asia/Seoul 기준 시각 생성.
    private func seoul(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = T.serverTimeZone
        return cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    func testMonthKeyUsesSeoulCalendarNotDeviceTimeZone() {
        // UTC 11-30 16:00 = Seoul 12-01 01:00 → 서버와 같은 "2026-12".
        let utc = TimeZone(identifier: "UTC")!
        var cal = Calendar(identifier: .gregorian); cal.timeZone = utc
        let d = cal.date(from: DateComponents(year: 2026, month: 11, day: 30, hour: 16))!
        XCTAssertEqual(T.monthKey(for: d), "2026-12")
    }

    func testFirstSyncCreditsCurrentMonthOnly() {
        let r = T.reconcile(monthlyVP: 2_300, now: seoul(2026, 11, 9),
                            baseline: .init(month: "", seenVP: 0))
        XCTAssertEqual(r.delta, 2_300)
        XCTAssertEqual(r.baseline, .init(month: "2026-11", seenVP: 2_300))
    }

    func testSameMonthCreditsOnlyIncrease() {
        let r = T.reconcile(monthlyVP: 2_800, now: seoul(2026, 11, 20),
                            baseline: .init(month: "2026-11", seenVP: 2_300))
        XCTAssertEqual(r.delta, 500)
        XCTAssertEqual(r.baseline.seenVP, 2_800)
    }

    func testSameMonthDecreaseCreditsNothingAndKeepsBaseline() {
        // 서버 trim/정산으로 월간 값이 줄어도 기준선은 뒤로 가지 않는다 — 돌아올 때 이중 적립 방지.
        let r = T.reconcile(monthlyVP: 2_000, now: seoul(2026, 11, 21),
                            baseline: .init(month: "2026-11", seenVP: 2_300))
        XCTAssertEqual(r.delta, 0)
        XCTAssertEqual(r.baseline, .init(month: "2026-11", seenVP: 2_300))
        // 다시 2,300으로 돌아와도 0, 2,400이 되면 100만.
        let back = T.reconcile(monthlyVP: 2_400, now: seoul(2026, 11, 22), baseline: r.baseline)
        XCTAssertEqual(back.delta, 100)
    }

    func testNewMonthCreditsWholeNewValue() {
        let r = T.reconcile(monthlyVP: 150, now: seoul(2026, 12, 3),
                            baseline: .init(month: "2026-11", seenVP: 2_800))
        XCTAssertEqual(r.delta, 150)
        XCTAssertEqual(r.baseline, .init(month: "2026-12", seenVP: 150))
    }

    func testNewMonthWithZeroMovesBaselineWithoutCredit() {
        let r = T.reconcile(monthlyVP: 0, now: seoul(2026, 12, 1, 0, 10),
                            baseline: .init(month: "2026-11", seenVP: 2_800))
        XCTAssertEqual(r.delta, 0)
        XCTAssertEqual(r.baseline, .init(month: "2026-12", seenVP: 0))
    }

    func testRolloverGraceDefersWhenServerStillOnPreviousMonth() {
        // 12-01 00:10 Seoul, 서버가 아직 11월 값(2,800)을 돌려줌 → 보류(이중 적립 방지), 기준선 유지.
        let r = T.reconcile(monthlyVP: 2_800, now: seoul(2026, 12, 1, 0, 10),
                            baseline: .init(month: "2026-11", seenVP: 2_800))
        XCTAssertEqual(r.delta, 0)
        XCTAssertEqual(r.baseline, .init(month: "2026-11", seenVP: 2_800))
        // 유예가 지나면 같은 값이라도 새 달로 인정 — 실제로 새 달에 그만큼 벌었다는 뜻.
        let later = T.reconcile(monthlyVP: 2_800, now: seoul(2026, 12, 1, 2, 0),
                                baseline: .init(month: "2026-11", seenVP: 2_800))
        XCTAssertEqual(later.delta, 2_800)
    }

    func testRolloverGraceDoesNotApplyToFirstSync() {
        let r = T.reconcile(monthlyVP: 900, now: seoul(2026, 12, 1, 0, 5),
                            baseline: .init(month: "", seenVP: 0))
        XCTAssertEqual(r.delta, 900)
    }

    func testNegativeServerValueIsClamped() {
        let r = T.reconcile(monthlyVP: -5, now: seoul(2026, 11, 9), baseline: .init(month: "", seenVP: 0))
        XCTAssertEqual(r.delta, 0)
        XCTAssertEqual(r.baseline.seenVP, 0)
    }

    @MainActor
    func testRecordAccumulatesIntoSettingsAndFeedsBadgeMetric() {
        let s = Settings.shared
        XCTAssertEqual(s.guildContributionTotal, 0)
        T.record(myMonthlyVP: 120, now: seoul(2026, 11, 9))
        XCTAssertEqual(s.guildContributionTotal, 120)
        XCTAssertEqual(s.guildContributionSyncMonth, "2026-11")
        XCTAssertEqual(s.guildContributionSyncSeenVP, 120)
        XCTAssertEqual(BadgeCategory.guildContribution.currentValue(s), 120)

        T.record(myMonthlyVP: 120, now: seoul(2026, 11, 10))   // 변화 없음
        XCTAssertEqual(s.guildContributionTotal, 120)
        T.record(myMonthlyVP: 400, now: seoul(2026, 11, 25))   // +280
        XCTAssertEqual(s.guildContributionTotal, 400)
        T.record(myMonthlyVP: 50, now: seoul(2026, 12, 5))     // 새 달 +50
        XCTAssertEqual(s.guildContributionTotal, 450)
        XCTAssertEqual(s.guildContributionSyncMonth, "2026-12")
        XCTAssertEqual(s.guildContributionSyncSeenVP, 50)
    }

    @MainActor
    func testServerTotalBackfillsPastMonthsWithoutDoubleCounting() {
        let s = Settings.shared
        // v0.19.4에서 11월분 2,300만 적립된 상태.
        T.record(myMonthlyVP: 2_300, now: seoul(2026, 11, 9))
        XCTAssertEqual(s.guildContributionTotal, 2_300)

        // 서버가 가입 이후 누적 30,000(11월 2,500 포함)을 내려줌 → 더하지 않고 끌어올린다.
        T.record(myMonthlyVP: 2_500, serverTotal: 30_000, now: seoul(2026, 11, 12))
        XCTAssertEqual(s.guildContributionTotal, 30_000)
        XCTAssertEqual(s.guildContributionSyncSeenVP, 2_500)

        // 이후 월간 증가분과 서버 누적이 같이 늘어도 한 번만 반영된다.
        T.record(myMonthlyVP: 2_900, serverTotal: 30_400, now: seoul(2026, 11, 20))
        XCTAssertEqual(s.guildContributionTotal, 30_400)
    }

    @MainActor
    func testServerTotalNeverLowersLocalTotal() {
        let s = Settings.shared
        // 이전 길드에서 쌓은 분이 로컬에 있고, 새 길드의 서버 누적은 그보다 작다.
        T.record(myMonthlyVP: 5_000, now: seoul(2026, 11, 9))
        T.record(myMonthlyVP: 5_000, serverTotal: 800, now: seoul(2026, 11, 10))
        XCTAssertEqual(s.guildContributionTotal, 5_000)
        // 로컬이 앞서 있는 동안에도 월간 증가분은 계속 쌓인다.
        T.record(myMonthlyVP: 5_200, serverTotal: 1_000, now: seoul(2026, 11, 11))
        XCTAssertEqual(s.guildContributionTotal, 5_200)
    }

    @MainActor
    func testServerTotalAloneBackfillsWhenMonthlyUnchanged() {
        let s = Settings.shared
        T.record(myMonthlyVP: 120, now: seoul(2026, 11, 9))
        // 월간 값은 그대로인데 서버 누적 필드가 새로 생긴 경우(서버 배포 직후).
        T.record(myMonthlyVP: 120, serverTotal: 9_000, now: seoul(2026, 11, 9))
        XCTAssertEqual(s.guildContributionTotal, 9_000)
        XCTAssertEqual(BadgeCategory.guildContribution.currentValue(s), 9_000)
    }
}
