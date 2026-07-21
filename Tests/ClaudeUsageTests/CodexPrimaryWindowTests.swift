import XCTest
@testable import ClaudeUsage

// #151 회귀 가드 — Codex 응답이 주간(7일) 창만 올 때(5시간·월간 없음) 대표 창이 주간으로
// 폴백해 사용량이 표시되는지. 이전엔 codexPrimaryPct가 (fiveHour ?? monthly)만 봐서 주간-only
// 응답이면 nil → 큰 숫자·프로그레스 바가 빈 값(카드는 뜨지만 수치 안 보임)이 됐다.
final class CodexPrimaryWindowTests: XCTestCase {

    private func snap(five: Double? = nil, seven: Double? = nil, month: Double? = nil,
                      now: Date = Date()) -> CodexSnapshot {
        CodexSnapshot(
            takenAt: now, plan: .pro, planName: "pro",
            fiveHourPct: five,  fiveHourResetAt: five  != nil ? now.addingTimeInterval(3600)      : nil,
            sevenDayPct: seven, sevenDayResetAt: seven != nil ? now.addingTimeInterval(7 * 86400)  : nil,
            monthlyPct: month,  monthlyResetAt: month  != nil ? now.addingTimeInterval(30 * 86400) : nil,
            creditsBalance: nil, hasCredits: nil)
    }

    // 핵심 회귀: 주간 창만 온 Pro 응답 → 대표 창=주간, 사용률 표시.
    @MainActor func testWeeklyOnlyShowsAsPrimary() {
        let vm = ViewModel()
        vm.codexCurrent = snap(seven: 3)
        XCTAssertEqual(vm.codexPrimaryWindow, .weekly)
        XCTAssertEqual(vm.codexPrimaryPct, 3)
        XCTAssertFalse(vm.codexUsesFiveHour)
        XCTAssertEqual(vm.codexPrimaryLabel, "주간")
        XCTAssertEqual(vm.codexPrimaryPeriodLength, 7 * 86400)
        XCTAssertNotNil(vm.codexPrimaryResetAt)
    }

    // 정상(5h+7d): 5시간이 대표(기존 동작 불변), 주간은 보조.
    @MainActor func testFiveHourTakesPriorityWhenPresent() {
        let vm = ViewModel()
        vm.codexCurrent = snap(five: 12, seven: 40)
        XCTAssertEqual(vm.codexPrimaryWindow, .fiveHour)
        XCTAssertEqual(vm.codexPrimaryPct, 12)
        XCTAssertTrue(vm.codexUsesFiveHour)
        XCTAssertEqual(vm.codexPrimaryPeriodLength, 5 * 3600)
    }

    // free(월간 단일): 대표=월간.
    @MainActor func testMonthlyOnly() {
        let vm = ViewModel()
        vm.codexCurrent = snap(month: 55)
        XCTAssertEqual(vm.codexPrimaryWindow, .monthly)
        XCTAssertEqual(vm.codexPrimaryPct, 55)
        XCTAssertEqual(vm.codexPrimaryLabel, "월간")
    }

    // 스냅샷 없음: 대표 창 none, 값 nil.
    @MainActor func testNoSnapshot() {
        let vm = ViewModel()
        vm.codexCurrent = nil
        XCTAssertEqual(vm.codexPrimaryWindow, ViewModel.CodexPrimaryWindow.none)
        XCTAssertNil(vm.codexPrimaryPct)
    }

    // 차트 시계열도 주간-only 히스토리에서 주간 값을 뽑아야 한다(차트도 안 빈다).
    func testPrimarySeriesWeeklyOnly() {
        let t0 = Date(timeIntervalSince1970: 1_780_000_000)
        let reset = t0.addingTimeInterval(7 * 86400)
        func s(_ takenAt: Date, _ seven: Double) -> CodexSnapshot {
            CodexSnapshot(takenAt: takenAt, plan: .pro, planName: "pro",
                fiveHourPct: nil, fiveHourResetAt: nil,
                sevenDayPct: seven, sevenDayResetAt: reset,
                monthlyPct: nil, monthlyResetAt: nil, creditsBalance: nil, hasCredits: nil)
        }
        let hist = [s(t0, 3), s(t0.addingTimeInterval(300), 5)]
        let series = ViewModel.codexPrimarySeries(hist)
        XCTAssertEqual(series.map { $0.1 }, [3, 5])
    }

    // 5시간 히스토리는 기존대로 5시간 시계열(주간 폴백이 정상 케이스를 가로채지 않음).
    func testPrimarySeriesFiveHourUnaffected() {
        let t0 = Date(timeIntervalSince1970: 1_780_000_000)
        let reset = t0.addingTimeInterval(3600)
        func s(_ takenAt: Date, _ five: Double) -> CodexSnapshot {
            CodexSnapshot(takenAt: takenAt, plan: .pro, planName: "pro",
                fiveHourPct: five, fiveHourResetAt: reset,
                sevenDayPct: 40, sevenDayResetAt: t0.addingTimeInterval(7 * 86400),
                monthlyPct: nil, monthlyResetAt: nil, creditsBalance: nil, hasCredits: nil)
        }
        let hist = [s(t0, 8), s(t0.addingTimeInterval(300), 9)]
        let series = ViewModel.codexPrimarySeries(hist)
        XCTAssertEqual(series.map { $0.1 }, [8, 9])   // 5h 값(주간 40이 아님)
    }
}
