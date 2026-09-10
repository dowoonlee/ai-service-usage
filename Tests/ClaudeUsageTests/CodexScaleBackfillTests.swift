import XCTest
@testable import ClaudeUsage

/// Codex 7d 창 스케일과 그 소급 지급.
///
/// 잠그는 계약:
///   - 7d 단독 응답은 월 대표 스케일(1068.2)로 적립한다 — 그래야 plan 가격 = 월 최대 VP가 성립
///   - 5h가 함께 오면 옛 스케일(60)로 돌아간다 — OpenAI가 5h를 되살리면 17.8배 과다 적립이 된다
///   - 소급은 이번 달분만, baseline은 지난달에서 이어받는다
///   - 소급 지급은 사이클당 상한을 넘지 않는다 — 서버 캡(floor 5,000)이 초과분을 조용히 버린다
@MainActor
final class CodexScaleBackfillTests: SandboxedTestCase {

    private let window = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run { registerLedgers() }
    }

    private func sevenDay(_ pct: Double, at takenAt: Date? = nil, resetAt: Date? = nil,
                          plan: String = "pro", fiveHourPct: Double? = nil) -> CodexSnapshot {
        CodexSnapshot(takenAt: takenAt ?? Date(), plan: .pro, planName: plan,
                      fiveHourPct: fiveHourPct,
                      fiveHourResetAt: fiveHourPct == nil ? nil : (resetAt ?? window),
                      sevenDayPct: pct, sevenDayResetAt: resetAt ?? window)
    }

    // MARK: - 스케일

    // Pro가 7d 창을 매달 다 태우면 정책 목표(가격 = $200 = 20,000 VP)에 닿아야 한다.
    // 옛 스케일(60)에서는 1,123 VP — 목표의 5.6% — 에서 멈췄다.
    func testSevenDayOnlyReachesPlanPriceOverAMonth() {
        let s = Settings.shared
        s.rankingScoreEarnedVP = 0
        UsageEventProducer.ingestCodex(sevenDay(0))
        UsageEventProducer.ingestCodex(sevenDay(100))

        let perWindow = Double(s.rankingScoreEarnedVP)
        let monthly = perWindow * 30.0 / 7.0
        XCTAssertEqual(monthly, 20_000, accuracy: 50,
                       "7d 창 만점 × 월 창수가 plan 가격(20,000 VP)과 어긋난다")
    }

    // coin도 같은 스케일을 타야 한다 — VP만 고치면 Codex Pro가 Claude Pro의 1/7에 머문다.
    func testSevenDayOnlyScalesCoinsToo() {
        let s = Settings.shared
        s.coins = 0
        UsageEventProducer.ingestCodex(sevenDay(0))
        UsageEventProducer.ingestCodex(sevenDay(100))

        // curve(1) × 1068.2 × Pro 배수 2.5
        XCTAssertEqual(Double(s.coins), 2_670, accuracy: 2)
        XCTAssertEqual(s.codexCoinsEarned, s.coins, "vibe 카운터(②)에 반영되지 않았다")
    }

    // 회귀 가드: 5h가 돌아오면 스케일도 돌아가야 한다. 이 분기가 없으면 그때부터 17.8배가 나간다.
    func testFiveHourPresentKeepsLegacyScale() {
        let s = Settings.shared
        s.coins = 0
        UsageEventProducer.ingestCodex(sevenDay(0, fiveHourPct: 0))
        UsageEventProducer.ingestCodex(sevenDay(100, fiveHourPct: 0))

        // 5h는 0으로 멈춰 있으므로 7d 몫만: curve(1) × 60 × 2.5
        XCTAssertEqual(s.coins, 150)
    }

    // MARK: - 소급 계산

    func testBackfillCoversCurrentMonthOnly() {
        let monthStart = Date(timeIntervalSince1970: 1_800_000_000)
        let snaps = [
            sevenDay(0,  at: monthStart.addingTimeInterval(-7200)),   // 지난달: baseline
            sevenDay(40, at: monthStart.addingTimeInterval(-3600)),   // 지난달 상승 — 소급 대상 아님
            sevenDay(100, at: monthStart.addingTimeInterval(3600)),   // 이번 달 상승분만
        ]
        let owed = CodexBackfill.compute(snapshots: snaps, since: monthStart)

        // 40→100 구간의 누락분 = (curve(1)-curve(0.4)) × (1068.2 - 60)
        let expectedPure = (1.0 - (0.4 as Double).squareRoot()) * (CoinLedger.codexSevenDayOnlyMaxCoin - 60)
        XCTAssertEqual(Double(owed.coins), expectedPure * 2.5, accuracy: 2)
        XCTAssertEqual(Double(owed.vp), expectedPure * 20_000 / 4578, accuracy: 2)
    }

    // 지난달 baseline을 안 이어받으면 이번 달 첫 스냅샷의 40%가 통째로 소급 대상이 된다.
    func testBackfillInheritsBaselineFromPreviousMonth() {
        let monthStart = Date(timeIntervalSince1970: 1_800_000_000)
        let withHistory = CodexBackfill.compute(
            snapshots: [sevenDay(40, at: monthStart.addingTimeInterval(-3600)),
                        sevenDay(40, at: monthStart.addingTimeInterval(3600))],
            since: monthStart)
        XCTAssertEqual(withHistory, .zero, "이번 달에 오르지 않았는데 소급이 잡혔다")
    }

    // 5h가 함께 오던 구간은 이미 제 스케일로 적립됐다 — 돌려줄 게 없다.
    func testBackfillIgnoresWindowsThatHadFiveHour() {
        let monthStart = Date(timeIntervalSince1970: 1_800_000_000)
        let owed = CodexBackfill.compute(
            snapshots: [sevenDay(0,   at: monthStart.addingTimeInterval(60),  fiveHourPct: 0),
                        sevenDay(100, at: monthStart.addingTimeInterval(120), fiveHourPct: 0)],
            since: monthStart)
        XCTAssertEqual(owed, .zero)
    }

    // 창이 바뀌면(resetAt 60s 초과 드리프트) rebase만 — 새 창의 시작 pct가 소급되면 안 된다.
    func testBackfillDoesNotCreditAcrossWindowChange() {
        let monthStart = Date(timeIntervalSince1970: 1_800_000_000)
        let owed = CodexBackfill.compute(
            snapshots: [sevenDay(0,  at: monthStart.addingTimeInterval(60)),
                        sevenDay(80, at: monthStart.addingTimeInterval(120),
                                 resetAt: window.addingTimeInterval(3600))],
            since: monthStart)
        XCTAssertEqual(owed, .zero, "창 전환 지점이 소급 적립됐다")
    }

    // MARK: - 분납 지급

    func testDrainSplitsAcrossCyclesPreservingTotal() {
        let s = Settings.shared
        s.rankingScoreEarnedVP = 0
        s.coins = 0
        s.pendingCodexBackfillVP = 5_052        // 실측 소급액
        s.pendingCodexBackfillCoins = 2_891

        var cycles = 0
        while !CodexBackfill.drain().isEmpty {
            cycles += 1
            XCTAssertLessThan(cycles, 20, "소진되지 않고 도는 중")
        }
        XCTAssertEqual(s.rankingScoreEarnedVP, 5_052)
        XCTAssertEqual(s.coins, 2_891)
        XCTAssertEqual(s.pendingCodexBackfillVP, 0)
        XCTAssertEqual(s.pendingCodexBackfillCoins, 0)
        XCTAssertEqual(cycles, 6, "5,052 / 1,000 = 6 사이클")
    }

    // 한 사이클 지급액이 서버 캡 floor(5,000)를 넘으면 초과분이 조용히 잘린다.
    func testSingleDrainStaysUnderServerCapFloor() {
        let s = Settings.shared
        s.pendingCodexBackfillVP = 50_000
        s.pendingCodexBackfillCoins = 50_000
        let paid = CodexBackfill.drain()
        XCTAssertLessThanOrEqual(paid.vp, 5_000)
        XCTAssertEqual(paid.vp, CodexBackfill.drainPerCycle)
    }

    func testDrainOnEmptyQueueIsNoop() {
        let s = Settings.shared
        s.rankingScoreEarnedVP = 7
        XCTAssertEqual(CodexBackfill.drain(), .zero)
        XCTAssertEqual(s.rankingScoreEarnedVP, 7)
    }
}
