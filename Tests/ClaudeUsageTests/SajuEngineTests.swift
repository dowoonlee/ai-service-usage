import XCTest
@testable import ClaudeUsage

/// 사주 계산 — 운세 화면의 근간.
///
/// 순수 계산인데 테스트가 없었다. 틀려도 "그럴듯한 다른 결과"가 나오는 종류라 눈으로는
/// 절대 못 잡는다. 경계(입춘·절기·자시)와 순환 규칙을 고정해둔다.
///
/// 기준값은 만세력의 공지된 값을 쓴다. 계산식을 리팩터할 때 결과가 같은지만 보면 된다.
final class SajuEngineTests: XCTestCase {

    private let kst = TimeZone(identifier: "Asia/Seoul")!

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = kst
        return cal.date(from: DateComponents(timeZone: kst, year: y, month: m, day: d, hour: h))!
    }

    // MARK: - 년주: 입춘 경계

    /// 사주의 해는 1월 1일이 아니라 **입춘(2월 4일경)**에 바뀐다. 이 경계를 놓치면
    /// 1~2월 초 생일인 사람의 사주가 통째로 한 해 밀린다.
    func testYearPillarFlipsAtIpchunNotNewYear() {
        // 2000-02-03 = 아직 1999년(기묘)
        let before = SajuEngine.chart(for: date(2000, 2, 3), in: kst)
        // 2000-02-04 = 2000년(경진)
        let after = SajuEngine.chart(for: date(2000, 2, 4), in: kst)
        XCTAssertNotEqual(before.year.stem, after.year.stem, "입춘에 년간이 바뀌어야 한다")
        XCTAssertEqual(after.year.stem, .gyeong)   // 2000년 = 경진
        XCTAssertEqual(after.year.branch, .jin)
        XCTAssertEqual(before.year.stem, .gi)      // 1999년 = 기묘
        XCTAssertEqual(before.year.branch, .myo)

        // 1월 1일은 여전히 전년도.
        XCTAssertEqual(SajuEngine.chart(for: date(2000, 1, 1), in: kst).year.branch, .myo)
    }

    /// 60갑자 순환 — 60년 전과 같은 간지여야 한다.
    func testYearPillarCyclesEverySixtyYears() {
        let a = SajuEngine.chart(for: date(1984, 6, 1), in: kst).year
        let b = SajuEngine.chart(for: date(2044, 6, 1), in: kst).year
        XCTAssertEqual(a.stem, b.stem)
        XCTAssertEqual(a.branch, b.branch)
    }

    // MARK: - 월주: 절기 경계 + 오호둔

    /// 월지는 양력 월이 아니라 절기로 끊는다. 경계 하루 차이로 지지가 바뀐다.
    func testMonthBranchFollowsSolarTermsNotCalendarMonth() {
        XCTAssertEqual(SajuEngine.chart(for: date(2026, 2, 3), in: kst).month.branch, .chuk, "입춘 전 = 축월")
        XCTAssertEqual(SajuEngine.chart(for: date(2026, 2, 4), in: kst).month.branch, .inwol, "입춘 = 인월")
        XCTAssertEqual(SajuEngine.chart(for: date(2026, 8, 6), in: kst).month.branch, .mi, "입추 전 = 미월")
        XCTAssertEqual(SajuEngine.chart(for: date(2026, 8, 7), in: kst).month.branch, .sin, "입추 = 신월")
        XCTAssertEqual(SajuEngine.chart(for: date(2026, 12, 7), in: kst).month.branch, .ja, "대설 = 자월")
    }

    /// 모든 (월, 일)이 12지지 중 하나로 떨어져야 한다 — 표에 구멍이 있으면 `.ja` 폴백으로
    /// 조용히 잘못된 값이 나온다.
    func testEveryDayMapsToAMonthBranch() {
        var seen = Set<EarthlyBranch>()
        for m in 1...12 {
            for d in [1, 4, 5, 6, 7, 8, 15, 28] {
                seen.insert(SajuEngine.chart(for: date(2026, m, d), in: kst).month.branch)
            }
        }
        XCTAssertEqual(seen.count, 12, "12지지가 모두 나와야 한다 — 빠진 게 있으면 표에 구멍")
    }

    /// 오호둔(五虎遁): 년간에 따라 인월의 천간이 정해지고 거기서 순행한다.
    /// 甲己→丙寅 / 乙庚→戊寅 / 丙辛→庚寅 / 丁壬→壬寅 / 戊癸→甲寅
    func testMonthStemFollowsOhodun() {
        // 2024년 = 갑진년 → 인월은 병인
        let gap = SajuEngine.chart(for: date(2024, 2, 10), in: kst)
        XCTAssertEqual(gap.year.stem, .gap)
        XCTAssertEqual(gap.month.branch, .inwol)
        XCTAssertEqual(gap.month.stem, .byeong, "갑년의 인월은 병인")

        // 2025년 = 을사년 → 인월은 무인
        let eul = SajuEngine.chart(for: date(2025, 2, 10), in: kst)
        XCTAssertEqual(eul.year.stem, .eul)
        XCTAssertEqual(eul.month.stem, .mu, "을년의 인월은 무인")
    }

    // MARK: - 일주

    /// 일주는 기준일(1900-01-31 = 갑진)에서 경과일로 센다. 하루 지나면 간지도 하나씩 나아간다.
    func testDayPillarAdvancesOnePerDay() {
        let d1 = SajuEngine.chart(for: date(2026, 8, 12), in: kst).day
        let d2 = SajuEngine.chart(for: date(2026, 8, 13), in: kst).day
        XCTAssertEqual((d1.stem.rawValue + 1) % 10, d2.stem.rawValue)
        XCTAssertEqual((d1.branch.rawValue + 1) % 12, d2.branch.rawValue)
    }

    func testDayPillarAtReferenceDate() {
        let ref = SajuEngine.chart(for: date(1900, 1, 31), in: kst).day
        XCTAssertEqual(ref.stem, .gap, "기준일은 갑")
        XCTAssertEqual(ref.branch, .jin, "기준일은 진")
    }

    /// 60일 주기로 같은 일주가 돌아온다.
    func testDayPillarCyclesEverySixtyDays() {
        let a = SajuEngine.chart(for: date(2026, 1, 1), in: kst).day
        let b = SajuEngine.chart(for: date(2026, 3, 2), in: kst).day   // +60일
        XCTAssertEqual(a.stem, b.stem)
        XCTAssertEqual(a.branch, b.branch)
    }

    /// 시각이 달라도 같은 날이면 일주는 같다(자시 분할은 하지 않는 단순화).
    func testDayPillarIsStableWithinTheDay() {
        let morning = SajuEngine.chart(for: date(2026, 8, 12, 1), in: kst).day
        let evening = SajuEngine.chart(for: date(2026, 8, 12, 22), in: kst).day
        XCTAssertEqual(morning.stem, evening.stem)
        XCTAssertEqual(morning.branch, evening.branch)
    }

    // MARK: - 오행 분포

    /// 8글자(4주 × 간지)의 오행 합은 항상 8이어야 한다 — 하나라도 빠뜨리면 분포 그래프가 틀어진다.
    func testFiveElementCountsSumToEight() {
        for (y, m, d) in [(1990, 3, 15), (2000, 7, 1), (2026, 12, 31), (1984, 2, 4)] {
            let chart = SajuEngine.chart(for: date(y, m, d), in: kst)
            XCTAssertEqual(chart.fiveElementCounts.values.reduce(0, +), 8, "\(y)-\(m)-\(d)")
        }
    }

    // MARK: - 일일 운세

    /// 같은 날 + 같은 일간이면 항상 같은 운세다(결정적) — 새로고침마다 바뀌면 신뢰를 잃는다.
    func testDailyFortuneIsDeterministic() {
        let day = date(2026, 8, 12)
        let a = SajuEngine.daily(for: day, against: .gap, in: kst)
        let b = SajuEngine.daily(for: day, against: .gap, in: kst)
        XCTAssertEqual(a.today.stem, b.today.stem)
        XCTAssertEqual(a.relation, b.relation)
    }

    /// 일간이 다르면 같은 날이라도 관계가 달라진다 — 사용자마다 다른 운세가 나와야 한다.
    func testDailyFortuneVariesByUserDayStem() {
        let day = date(2026, 8, 12)
        let relations = HeavenlyStem.allCases.map { SajuEngine.daily(for: day, against: $0, in: kst).relation }
        XCTAssertGreaterThan(Set(relations).count, 1, "일간에 따라 관계가 갈려야 한다")
    }

    /// 오행 관계는 5종(비화·상생·피생·상극·피극)이 전부 나온다 — 10천간을 다 넣으면
    /// 그날의 원소를 기준으로 다섯 관계가 모두 성립해야 순환이 닫힌 것이다.
    func testAllFiveRelationsAppearAcrossStems() {
        let day = date(2026, 8, 12)
        let relations = Set(HeavenlyStem.allCases.map {
            SajuEngine.daily(for: day, against: $0, in: kst).relation
        })
        XCTAssertEqual(relations.count, 5, "관계 5종이 모두 나와야 순환이 닫힌다: \(relations)")

        // 그날의 일간과 같은 원소면 비화.
        let todayStem = SajuEngine.chart(for: day, in: kst).day.stem
        XCTAssertEqual(SajuEngine.daily(for: day, against: todayStem, in: kst).relation, .same)
    }
}
