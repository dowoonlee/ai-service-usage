import XCTest
@testable import ClaudeUsage

/// 리캡 집계 — 실데이터로 데모를 만들다 걸린 함정들을 고정한다. 셋 다 "그냥 합산"하면
/// 숫자가 그럴듯하게 틀려서 눈으로는 못 잡는다.
final class RecapFactsTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private let t0 = Date(timeIntervalSince1970: 1_780_000_000)   // 임의의 기준 시각
    private func h(_ hours: Double) -> Date { t0.addingTimeInterval(hours * 3600) }

    private func codex(_ pct: Double, at: Date, reset: Date) -> CodexSnapshot {
        CodexSnapshot(takenAt: at, plan: .pro, planName: "pro", sevenDayPct: pct, sevenDayResetAt: reset)
    }

    // Claude resetAt은 폴링마다 수 초씩 흔들린다. 창을 resetAt 값 그대로 묶으면 한 주가
    // 수십 개 창으로 쪼개져 "태운 한도"가 수십 장으로 부풀었다.
    func testClaudeWeeklyResetJitterStaysOneWindow() {
        let reset = h(100)
        let rows: [UsageSnapshot] = [
            .claude(sevenDayPct: 10, sevenDayResetAt: reset, takenAt: h(0)),
            .claude(sevenDayPct: 40, sevenDayResetAt: reset.addingTimeInterval(3), takenAt: h(1)),
            .claude(sevenDayPct: 60, sevenDayResetAt: reset.addingTimeInterval(-2), takenAt: h(2)),
            .claude(sevenDayPct: 30, sevenDayResetAt: reset.addingTimeInterval(7 * 86400), takenAt: h(110)),
        ]
        let f = RecapUsageFacts.compute(claude: rows, codex: [], cursor: [], now: h(120), calendar: cal)
        XCTAssertEqual(f.claudeWeeklyGauges, 0.9, accuracy: 1e-9, "창 2개(최고 60% + 30%)여야 한다")
        XCTAssertEqual(f.claudeWeeklyPeak?.pct, 60)
    }

    // Codex 7일 창은 롤링이라 resetAt이 계속 밀린다. 창으로 묶으면 2,600개 창이 나왔다.
    // 연속 스냅샷의 증가분만 더한다 — 줄어드는 구간(오래된 사용분이 빠짐)은 무시.
    func testCodexRollingWindowSumsIncrements() {
        let rows = [
            codex(10, at: h(0), reset: h(168)),
            codex(20, at: h(1), reset: h(170)),
            codex(15, at: h(2), reset: h(175)),
            codex(25, at: h(3), reset: h(181)),
        ]
        let f = RecapUsageFacts.compute(claude: [], codex: rows, cursor: [], now: h(4), calendar: cal)
        XCTAssertEqual(f.codexWeeklyGauges, 0.2, accuracy: 1e-9)
        XCTAssertEqual(f.codexWeeklyPeak?.pct, 25)
    }

    // 로그인 직후 등에 %가 빈 행(takenAt만)이 섞인다. 쌍으로 비교하기 전에 걸러야
    // 10 → (빈 행) → 30 의 20%p가 사라지지 않는다.
    func testEmptyRowsDoNotSwallowActivity() {
        let reset = h(5)
        let rows: [UsageSnapshot] = [
            .claude(fiveHourPct: 10, fiveHourResetAt: reset, takenAt: h(0)),
            UsageSnapshot(takenAt: h(0.5)),
            .claude(fiveHourPct: 30, fiveHourResetAt: reset, takenAt: h(1)),
        ]
        let f = RecapUsageFacts.compute(claude: rows, codex: [], cursor: [], now: h(2), calendar: cal)
        XCTAssertEqual(f.daily.reduce(0, +), 20, accuracy: 1e-9)
    }

    // 5시간 창이 바뀌는 순간의 % 하락→상승은 사용량이 아니다(새 창의 시작).
    func testFiveHourWindowRolloverIsNotActivity() {
        let rows: [UsageSnapshot] = [
            .claude(fiveHourPct: 90, fiveHourResetAt: h(5), takenAt: h(4)),
            .claude(fiveHourPct: 95, fiveHourResetAt: h(10), takenAt: h(6)),
        ]
        let f = RecapUsageFacts.compute(claude: rows, codex: [], cursor: [], now: h(7), calendar: cal)
        XCTAssertEqual(f.daily.reduce(0, +), 0)
    }

    // 벽 충돌은 스냅샷 수가 아니라 창 수로 센다 — 100%에 머문 채 폴링이 여러 번 찍혀도 1회.
    func testFiveHourWallHitsCountWindows() {
        let rows: [UsageSnapshot] = [
            .claude(fiveHourPct: 100, fiveHourResetAt: h(5), takenAt: h(3)),
            .claude(fiveHourPct: 100, fiveHourResetAt: h(5), takenAt: h(4)),
            .claude(fiveHourPct: 70, fiveHourResetAt: h(10), takenAt: h(6)),
            .claude(fiveHourPct: 100, fiveHourResetAt: h(15), takenAt: h(12)),
        ]
        let f = RecapUsageFacts.compute(claude: rows, codex: [], cursor: [], now: h(13), calendar: cal)
        XCTAssertEqual(f.claudeFiveHourWallHits, 2)
    }

    // 저장소는 append 순서라 정렬을 보장하지 않는다(백필 등). 집계 전에 정렬해야 한다.
    func testUnsortedInputIsSortedFirst() {
        let reset = h(5)
        let sorted: [UsageSnapshot] = [
            .claude(fiveHourPct: 10, fiveHourResetAt: reset, takenAt: h(0)),
            .claude(fiveHourPct: 30, fiveHourResetAt: reset, takenAt: h(1)),
            .claude(fiveHourPct: 50, fiveHourResetAt: reset, takenAt: h(2)),
        ]
        let a = RecapUsageFacts.compute(claude: sorted, codex: [], cursor: [], now: h(3), calendar: cal)
        let b = RecapUsageFacts.compute(claude: sorted.reversed(), codex: [], cursor: [], now: h(3), calendar: cal)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.daily.reduce(0, +), 40, accuracy: 1e-9)
    }

    // 연속 일수: 오늘 아직 안 썼다고 연속이 0으로 떨어지면 안 된다. 이틀 비면 끊긴다.
    func testStreaks() {
        let day = 86400.0
        func active(_ d: Double) -> [CodexSnapshot] {
            [codex(10, at: t0.addingTimeInterval(d * day), reset: h(999)),
             codex(20, at: t0.addingTimeInterval(d * day + 600), reset: h(999))]
        }
        // 0,1,2일 활동 · 3일 쉼 · 4,5일 활동 · 6일(오늘) 아직
        let rows = [0, 1, 2, 4, 5].flatMap { active(Double($0)) }
        let f = RecapUsageFacts.compute(claude: [], codex: rows, cursor: [], now: t0.addingTimeInterval(6 * day), calendar: cal)
        XCTAssertEqual(f.longestStreak, 3)
        XCTAssertEqual(f.currentStreak, 2, "오늘 아직 안 썼으면 어제까지의 연속")
        XCTAssertEqual(f.activeDays, 5)

        let lapsed = RecapUsageFacts.compute(claude: [], codex: rows, cursor: [], now: t0.addingTimeInterval(7 * day), calendar: cal)
        XCTAssertEqual(lapsed.currentStreak, 0, "이틀 비면 끊긴다")
    }

    func testCursorTotalsAndTopModel() {
        let ev = [
            CursorEvent(timestamp: h(0), model: "a", chargedCents: 150),
            CursorEvent(timestamp: h(1), model: "b", chargedCents: 50),
            CursorEvent(timestamp: h(2), model: "b", chargedCents: 0),
        ]
        let f = RecapUsageFacts.compute(claude: [], codex: [], cursor: ev, now: h(3), calendar: cal)
        XCTAssertEqual(f.cursorUSD, 2, accuracy: 1e-9)
        XCTAssertEqual(f.cursorTopModel, "b")
        XCTAssertEqual(f.cursorFirst, h(0))
    }
}

/// 리캡 이벤트 로그 — 보유 상태엔 "언제"가 남지 않아서, 여기서 안 쌓으면 연말에 복구할 길이 없다.
@MainActor
final class RecapLogTests: SandboxedTestCase {
    func testGachaCommitAppendsPullEvent() throws {
        let s = Settings.shared
        s.ownedPets = [:]
        s.coins = 1000
        let before = RecapLog.loadAll().count
        let pull = try Gacha.roll(useTicket: false)
        _ = Gacha.commit(pull)
        let events = RecapLog.loadAll()
        XCTAssertEqual(events.count, before + 1)
        let e = try XCTUnwrap(events.last)
        XCTAssertEqual(e.kind, .gachaPull)
        XCTAssertEqual(e.pet, pull.kind.rawValue)
        XCTAssertEqual(e.isNew, true)
    }

    // rawValue 문자열로 저장하므로 모르는 펫 이름이 와도 그 줄이 버려지지 않는다.
    func testUnknownPetNameStillDecodes() throws {
        let json = #"{"at":"2026-12-01T00:00:00Z","kind":"gachaPull","pet":"removedPet","rarity":"common"}"#
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let e = try d.decode(RecapEvent.self, from: Data(json.utf8))
        XCTAssertEqual(e.pet, "removedPet")
    }
}
