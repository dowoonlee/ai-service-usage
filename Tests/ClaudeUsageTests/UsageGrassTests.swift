import XCTest
@testable import ClaudeUsage

/// 사용량 잔디 모델 + 일별 ledger. 날짜 경계는 전부 KST — 서버 보상·퀴즈와 같은 칸에 들어가야 한다.
final class UsageGrassModelTests: XCTestCase {
    private func utc(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = min
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: c)!
    }

    func testDayKeyUsesKSTBoundary() {
        // UTC 14:59 = KST 23:59 (같은 날) / UTC 15:00 = KST 00:00 (다음 날)
        XCTAssertEqual(UsageGrassModel.dayKey(utc(2026, 12, 24, 14, 59)), "2026-12-24")
        XCTAssertEqual(UsageGrassModel.dayKey(utc(2026, 12, 24, 15, 0)), "2026-12-25")
    }

    func testLevelQuartiles() {
        XCTAssertEqual(UsageGrassModel.level(vp: 0, max: 100), 0)
        XCTAssertEqual(UsageGrassModel.level(vp: 10, max: 100), 1)
        XCTAssertEqual(UsageGrassModel.level(vp: 25, max: 100), 2)
        XCTAssertEqual(UsageGrassModel.level(vp: 50, max: 100), 3)
        XCTAssertEqual(UsageGrassModel.level(vp: 75, max: 100), 4)
        XCTAssertEqual(UsageGrassModel.level(vp: 100, max: 100), 4)
        // 기준값이 없을 때(첫날) 양수는 최상위 — 첫날부터 불이 켜져야 한다.
        XCTAssertEqual(UsageGrassModel.level(vp: 1, max: 0), 4)
    }

    func testDecember2026GridStartsTuesdayAndHasFiveRows() {
        // 2026-12-01은 화요일 → 월요일 빈 칸 1개. 31일이면 5행(1칸 + 31일 = 32 → 35칸).
        let now = utc(2026, 12, 18, 3)   // KST 12/18 12:00
        let m = UsageGrassModel.build(dailyVP: ["2026-12-18": 500], now: now)
        XCTAssertEqual(m.year, 2026); XCTAssertEqual(m.month, 12)
        XCTAssertEqual(m.weeks.count, 5)
        XCTAssertNil(m.weeks[0][0].day)
        XCTAssertEqual(m.weeks[0][1].day, 1)
        XCTAssertEqual(m.weeks[4][3].day, 31)
        XCTAssertNil(m.weeks[4][4].day)
        XCTAssertEqual(m.elapsedDays, 18)
        let today = m.weeks.flatMap { $0 }.first { $0.isToday }
        XCTAssertEqual(today?.day, 18)
        XCTAssertEqual(today?.level, 4)
        // 미래 칸은 값이 있어도 0 — 시계가 앞선 데이터가 섞여도 미래는 비어 있어야 한다.
        let m2 = UsageGrassModel.build(dailyVP: ["2026-12-25": 900], now: now)
        let xmas = m2.weeks.flatMap { $0 }.first { $0.day == 25 }
        XCTAssertEqual(xmas?.isFuture, true)
        XCTAssertEqual(xmas?.level, 0)
        XCTAssertEqual(m2.totalVP, 0)
    }

    func testNovember2026SixRowsWhenMonthStartsSunday() {
        // 2026-11-01은 일요일 → 빈 칸 6개, 30일 → 36칸 → 6행.
        let m = UsageGrassModel.build(dailyVP: [:], now: utc(2026, 11, 10, 3))
        XCTAssertEqual(m.weeks.count, 6)
        XCTAssertEqual(m.weeks[0][6].day, 1)
        XCTAssertEqual(m.weeks[5][0].day, 30)
    }

    func testStatsSumOnlyThisMonthUpToToday() {
        let now = utc(2026, 12, 3, 3)
        let m = UsageGrassModel.build(dailyVP: [
            "2026-11-30": 1000,    // 지난달 — 합계 제외, 사분위 기준에는 포함
            "2026-12-01": 100, "2026-12-02": 0, "2026-12-03": 200,
        ], now: now)
        XCTAssertEqual(m.totalVP, 300)
        XCTAssertEqual(m.activeDays, 2)
        XCTAssertEqual(m.elapsedDays, 3)
        // 최근 30일 최대가 1000이라 200은 1단계.
        XCTAssertEqual(m.weeks.flatMap { $0 }.first { $0.day == 3 }?.level, 1)
    }

    func testRecentMaxWindowIsThirtyDaysInclusive() {
        let now = utc(2026, 12, 31, 3)   // KST 12/31
        let inWindow = UsageGrassModel.recentMax(dailyVP: ["2026-12-02": 50], now: now)   // 29일 전
        let outWindow = UsageGrassModel.recentMax(dailyVP: ["2026-12-01": 50], now: now)  // 30일 전
        XCTAssertEqual(inWindow, 50)
        XCTAssertEqual(outWindow, 0)
    }

    @MainActor
    func testGrassLevelsAreFiveAndBrightnessIncreases() {
        for theme in PetTheme.allCases {
            let levels = theme.grassLevels
            XCTAssertEqual(levels.count, 5, "\(theme)")
            var prev: CGFloat = -1
            for c in levels.dropFirst() {
                var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                NSColor(c).usingColorSpace(.deviceRGB)?.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
                XCTAssertGreaterThan(b, prev, "\(theme) 농도 단계가 단조 증가해야 함")
                XCTAssertGreaterThanOrEqual(s, 0.39, "\(theme) 채도 하한")
                prev = b
            }
        }
    }
}

@MainActor
final class DailyUsageLedgerTests: SandboxedTestCase {
    private func event(_ ts: Date, pure: Double, vpFactor: Double = 1) -> UsageEvent {
        UsageEvent(timestamp: ts, source: .claudeFiveHour,
                   context: UsageContext(planName: "Max", coinFactor: 1, vpFactor: vpFactor),
                   pureValue: pure)
    }

    func testAccumulatesPerKSTDay() {
        let s = Settings.shared
        let d1 = Date(timeIntervalSince1970: 1_797_000_000)   // 임의 시각
        DailyUsageLedger.shared.consume(event(d1, pure: 10, vpFactor: 2))
        DailyUsageLedger.shared.consume(event(d1, pure: 5, vpFactor: 2))
        let key = UsageGrassModel.dayKey(d1)
        XCTAssertEqual(s.dailyVP[key], 30)
        XCTAssertEqual(s.dailyVP.count, 1)
    }

    func testZeroVPFactorIsIgnored() {
        DailyUsageLedger.shared.consume(event(Date(), pure: 10, vpFactor: 0))
        XCTAssertTrue(Settings.shared.dailyVP.isEmpty)
    }

    func testPruneDropsEntriesOlderThanRetention() {
        var map: [String: Double] = ["2026-01-01": 1, "2026-11-30": 2, "2026-12-01": 3]
        var c = DateComponents(); c.year = 2026; c.month = 12; c.day = 1; c.hour = 12
        let now = Calendar.kst.date(from: c)!
        DailyUsageLedger.prune(&map, now: now)
        XCTAssertNil(map["2026-01-01"])
        XCTAssertEqual(map["2026-11-30"], 2)
        XCTAssertEqual(map["2026-12-01"], 3)
    }
}
