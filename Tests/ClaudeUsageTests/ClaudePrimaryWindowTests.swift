import XCTest
@testable import ClaudeUsage

// 2026-10-30 Ultra 개편 회귀 가드 — 인증된 Ultra 계정은 `/usage`의 `five_hour`가 `null`로 와서
// 5h만 보던 큰 숫자·스파크라인·펫·메뉴바가 통째로 비었다. Codex의 #151(`CodexPrimaryWindowTests`)과
// 같은 구조로 주간을 폴백 대표 창으로 둔다.
final class ClaudePrimaryWindowTests: XCTestCase {

    private func snap(five: Double? = nil, seven: Double? = nil, now: Date = Date()) -> UsageSnapshot {
        .claude(fiveHourPct: five, fiveHourResetAt: five != nil ? now.addingTimeInterval(3600) : nil,
                sevenDayPct: seven, sevenDayResetAt: seven != nil ? now.addingTimeInterval(7 * 86400) : nil,
                plan: "Ultra", takenAt: now)
    }

    // 핵심 회귀: 주간만 온 Ultra 응답 → 대표 창=주간, 큰 숫자·리셋·주기 길이가 주간 기준.
    @MainActor func testWeeklyOnlyShowsAsPrimary() {
        let vm = ViewModel()
        vm.claudeCurrent = snap(seven: 57)
        XCTAssertEqual(vm.claudePrimaryWindow, .weekly)
        XCTAssertEqual(vm.claudePrimaryPct, 57)
        XCTAssertFalse(vm.claudeUsesFiveHour)
        XCTAssertEqual(vm.claudePrimaryLabel, "주간")
        XCTAssertEqual(vm.claudePrimaryPeriodLength, 7 * 86400)
        XCTAssertNotNil(vm.claudePrimaryResetAt)
    }

    // 정상(5h+7d): 5시간이 대표(기존 동작 불변), 주간은 보조.
    @MainActor func testFiveHourTakesPriorityWhenPresent() {
        let vm = ViewModel()
        vm.claudeCurrent = snap(five: 12, seven: 40)
        XCTAssertEqual(vm.claudePrimaryWindow, .fiveHour)
        XCTAssertEqual(vm.claudePrimaryPct, 12)
        XCTAssertTrue(vm.claudeUsesFiveHour)
        XCTAssertEqual(vm.claudePrimaryLabel, "5시간 창")
        XCTAssertEqual(vm.claudePrimaryPeriodLength, 5 * 3600)
    }

    @MainActor func testNoSnapshot() {
        let vm = ViewModel()
        vm.claudeCurrent = nil
        XCTAssertEqual(vm.claudePrimaryWindow, ViewModel.ClaudePrimaryWindow.none)
        XCTAssertNil(vm.claudePrimaryPct)
    }

    // 차트/펫/메뉴바 시계열도 주간-only 히스토리에서 주간 값을 뽑아야 한다.
    func testPrimarySeriesWeeklyOnly() {
        let t0 = Date(timeIntervalSince1970: 1_780_000_000)
        let reset = t0.addingTimeInterval(7 * 86400)
        func s(_ takenAt: Date, _ seven: Double) -> UsageSnapshot {
            .claude(sevenDayPct: seven, sevenDayResetAt: reset, plan: "Ultra", takenAt: takenAt)
        }
        let hist = [s(t0, 3), s(t0.addingTimeInterval(300), 5)]
        XCTAssertEqual(ViewModel.claudePrimarySeries(hist).map { $0.1 }, [3, 5])
    }

    // 5시간 히스토리는 기존대로 5시간 시계열(주간 폴백이 정상 케이스를 가로채지 않음).
    func testPrimarySeriesFiveHourUnaffected() {
        let t0 = Date(timeIntervalSince1970: 1_780_000_000)
        func s(_ takenAt: Date, _ five: Double) -> UsageSnapshot {
            .claude(fiveHourPct: five, fiveHourResetAt: t0.addingTimeInterval(3600),
                    sevenDayPct: 40, sevenDayResetAt: t0.addingTimeInterval(7 * 86400),
                    plan: "Max", takenAt: takenAt)
        }
        let hist = [s(t0, 8), s(t0.addingTimeInterval(300), 9)]
        XCTAssertEqual(ViewModel.claudePrimarySeries(hist).map { $0.1 }, [8, 9])
    }

    // Max 20x → Ultra 전환 순간: 옛 스냅샷(5h 있음)이 섞여 있어도 대표 창은 **가장 최근** 기준이고,
    // 주간 리셋이 같은 옛 점은 주간 값으로 그대로 이어진다 — 전환 직후 차트가 비지 않는다.
    func testPrimarySeriesUsesLatestSnapshotToPickWindow() {
        let t0 = Date(timeIntervalSince1970: 1_780_000_000)
        let weeklyReset = t0.addingTimeInterval(7 * 86400)
        let before: UsageSnapshot = .claude(fiveHourPct: 30, fiveHourResetAt: t0.addingTimeInterval(3600),
                                            sevenDayPct: 50, sevenDayResetAt: weeklyReset,
                                            plan: "Max 20x", takenAt: t0)
        let after: UsageSnapshot = .claude(sevenDayPct: 52, sevenDayResetAt: weeklyReset,
                                           plan: "Ultra", takenAt: t0.addingTimeInterval(600))
        XCTAssertEqual(ViewModel.claudePrimarySeries([before, after]).map { $0.1 }, [50, 52])
    }
}
