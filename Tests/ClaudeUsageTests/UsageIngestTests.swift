import XCTest
@testable import ClaudeUsage

/// 사용량 → 코인 적립 상태머신 (`UsageEventProducer`).
///
/// `CoinCurveTests`는 `curve()` 곡선만 본다. 정작 돈이 만들어지는 지점 — 어느 delta를 적립하고
/// 어느 delta를 버리는가 — 은 `Settings.shared`에 직접 붙어 있어 테스트가 없었다.
///
/// 여기서 잠그는 계약은 셋이고, 셋 다 실패 모드가 "사용자 잔고가 조용히 틀어지는" 종류다:
///   - 첫 관측은 베이스라인만 잡는다(설치 직후 소급 적립 금지)
///   - 같은 창 안에서 베이스라인은 **후퇴하지 않는다**(rolling 윈도우의 pct 감소→재증가 이중 적립 금지)
///   - `resetAt`이 바뀌면 rebase만 하고 적립하지 않는다
@MainActor
final class UsageIngestTests: SandboxedTestCase {

    private let window = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run { registerLedgers() }
    }

    private func ingestClaude5h(_ pct: Double, resetAt: Date? = nil, plan: String = "Pro") {
        UsageEventProducer.ingestClaude(
            .claude(fiveHourPct: pct, fiveHourResetAt: resetAt ?? window, plan: plan))
    }

    // MARK: - 베이스라인

    // 설치 직후 첫 폴에서 이미 80%를 쓰고 있어도 그 80%는 남의 사용량이다 — 적립하지 않는다.
    func testFirstObservationSeedsBaselineWithoutCrediting() {
        let s = Settings.shared
        s.coins = 0
        ingestClaude5h(80)
        XCTAssertEqual(s.coins, 0, "첫 관측이 소급 적립됐다")
        XCTAssertEqual(s.lastClaudeFiveHourPctSeen, 80)
        XCTAssertEqual(s.lastClaudeFiveHourReset, window)
    }

    func testSameWindowIncreaseCredits() {
        let s = Settings.shared
        s.coins = 0
        ingestClaude5h(0)
        ingestClaude5h(100)
        // Pro 배수 1.0, 5h 만점 30코인 → 0→100%는 curve(1)*30 = 30코인.
        XCTAssertEqual(s.coins, 30)
    }

    // 핵심 회귀 가드: rolling 윈도우는 pct가 내려갔다 올라온다. 내려간 만큼 다시 적립하면
    // 같은 사용량으로 코인이 두 번 나온다.
    func testBaselineNeverRetreatsWithinWindow() {
        let s = Settings.shared
        s.coins = 0
        ingestClaude5h(0)
        ingestClaude5h(64)
        let afterPeak = s.coins
        XCTAssertGreaterThan(afterPeak, 0)

        ingestClaude5h(30)                       // 창이 굴러가 사용률이 내려감
        XCTAssertEqual(s.coins, afterPeak, "하락 구간에서 적립이 발생했다")
        XCTAssertEqual(s.lastClaudeFiveHourPctSeen, 64, "베이스라인이 후퇴했다")

        ingestClaude5h(64)                       // 같은 지점까지 재상승 — 이미 적립한 구간
        XCTAssertEqual(s.coins, afterPeak, "이미 적립한 구간이 재적립됐다")

        ingestClaude5h(100)                      // 최고점 갱신분만 추가 적립
        XCTAssertEqual(s.coins, 30)
    }

    // 여러 번에 나눠 올라도 총액은 한 번에 오른 것과 같아야 한다(분수 캐리가 잔돈을 삼키지 않는지).
    func testIncrementalPathMatchesSingleJump() {
        let s = Settings.shared
        s.coins = 0
        ingestClaude5h(0)
        for pct in stride(from: 5.0, through: 100.0, by: 5.0) { ingestClaude5h(pct) }
        let incremental = s.coins

        Settings.resetForTesting()
        registerLedgers()
        Settings.shared.coins = 0
        ingestClaude5h(0)
        ingestClaude5h(100)
        XCTAssertEqual(incremental, Settings.shared.coins, accuracy: 1,
                       "적립 경로에 따라 총액이 달라진다")
    }

    // MARK: - 윈도우 전환

    // 창이 바뀌면(resetAt 변경) 새 창의 현재 pct는 베이스라인일 뿐 — 적립 대상이 아니다.
    func testResetAtChangeRebasesWithoutCrediting() {
        let s = Settings.shared
        s.coins = 0
        ingestClaude5h(0)
        ingestClaude5h(50)
        let beforeRollover = s.coins

        let nextWindow = window.addingTimeInterval(5 * 3600)
        ingestClaude5h(90, resetAt: nextWindow)     // 새 창인데 pct가 더 높음
        XCTAssertEqual(s.coins, beforeRollover, "창 전환에서 소급 적립됐다")
        XCTAssertEqual(s.lastClaudeFiveHourPctSeen, 90)
        XCTAssertEqual(s.lastClaudeFiveHourReset, nextWindow)
    }

    // ISO 타임스탬프는 폴마다 미세하게 흔들린다. 60초 이내면 같은 창으로 봐야 적립이 이어진다.
    func testSubMinuteResetDriftStaysInSameWindow() {
        let s = Settings.shared
        s.coins = 0
        ingestClaude5h(0)
        ingestClaude5h(100, resetAt: window.addingTimeInterval(30))
        XCTAssertEqual(s.coins, 30, "30초 드리프트가 새 창으로 오인됐다")
    }

    func testResetDriftBeyondSlackIsANewWindow() {
        let s = Settings.shared
        s.coins = 0
        ingestClaude5h(0)
        ingestClaude5h(100, resetAt: window.addingTimeInterval(120))
        XCTAssertEqual(s.coins, 0, "2분 차이는 새 창으로 봐야 한다")
    }

    // MARK: - 플랜 배수

    func testPlanMultiplierScalesCredit() {
        let s = Settings.shared
        s.coins = 0
        ingestClaude5h(0, plan: "Max 20x")
        ingestClaude5h(100, plan: "Max 20x")
        XCTAssertEqual(s.coins, 75)     // 30 × 2.5
    }

    // MARK: - Codex

    // free 플랜은 monthly 단일 창만 온다. 같은 규칙(첫 관측 베이스라인 → 이후 delta)이 적용된다.
    func testCodexMonthlyFollowsSameStateMachine() {
        let s = Settings.shared
        s.coins = 0
        let snap = { (pct: Double) in
            CodexSnapshot(takenAt: Date(), plan: .free, planName: "free",
                          monthlyPct: pct, monthlyResetAt: self.window)
        }
        UsageEventProducer.ingestCodex(snap(20))
        XCTAssertEqual(s.coins, 0, "첫 관측이 적립됐다")
        UsageEventProducer.ingestCodex(snap(60))
        XCTAssertGreaterThan(s.coins, 0)
        let afterRise = s.coins
        UsageEventProducer.ingestCodex(snap(40))
        XCTAssertEqual(s.coins, afterRise, "monthly 창에서도 하락 구간은 적립 금지")
    }

    // MARK: - Cursor 이벤트

    // 이벤트 스트림은 겹쳐서 재수신된다(incremental fetch의 cutoff는 배타적). 이미 적립한
    // 타임스탬프가 다시 들어와도 두 번 적립되면 안 된다.
    func testCursorEventsCreditOncePerTimestamp() {
        let s = Settings.shared
        s.coins = 0
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let events = (0..<3).map {
            CursorEvent(timestamp: t0.addingTimeInterval(TimeInterval($0 * 60)),
                        model: "claude", chargedCents: 100)
        }
        UsageEventProducer.ingestCursorEvents(events)
        let first = s.coins
        XCTAssertEqual(first, 30)    // 300 cents × 0.1

        UsageEventProducer.ingestCursorEvents(events)          // 같은 배치 재수신
        XCTAssertEqual(s.coins, first, "이미 적립한 이벤트가 재적립됐다")

        let newer = [CursorEvent(timestamp: t0.addingTimeInterval(600), model: "claude", chargedCents: 50)]
        UsageEventProducer.ingestCursorEvents(events + newer)  // 겹침 + 신규
        XCTAssertEqual(s.coins, first + 5, "신규분만 적립돼야 한다")
    }
}
