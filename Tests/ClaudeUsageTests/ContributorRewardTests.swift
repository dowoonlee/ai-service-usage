import XCTest
@testable import ClaudeUsage

/// 기여 보상 단가와 소급 마이그레이션.
///
/// 단가 자체보다 **소급이 정확히 한 번만 일어나는지**가 중요하다. 이 마이그레이션은 PR 번호가
/// 아니라 플래그 하나로 dedup하므로, 두 번 도는 순간 지급액이 그대로 두 배가 된다.
/// 반대로 `creditedPRNumbers`가 비어 있는 사용자에게 도는 것도 막아야 한다 — 기여가 없는데
/// 플래그만 켜지는 건 무해하지만, 0건에 credit이 호출되면 이력에 빈 항목이 남는다.
@MainActor
final class ContributorRewardTests: SandboxedTestCase {

    private func setPRs(_ numbers: [Int]) {
        Settings.shared.creditedPRNumbers = Set(numbers)
    }

    // 현행 단가 — 바꾸려면 이 테스트를 같이 고치게 해서, 수치 변경이 눈에 띄도록 한다.
    func testCurrentRates() {
        XCTAssertEqual(CoinLedger.coinPerContributorPR, 2000)
        XCTAssertEqual(RankPointLedger.rpPerContributorPR, 1000)
    }

    // 신규 PR 적립: PR당 coin 2,000 + RP 1,000이 둘 다 들어온다.
    func testNewPRCreditsBothCurrencies() {
        let s = Settings.shared
        let coins0 = s.coins, rp0 = s.rp
        CoinLedger.shared.creditContributorBonus(prCount: 3)
        RankPointLedger.shared.creditContributorBonus(prCount: 3)
        XCTAssertEqual(s.coins - coins0, 6000)
        XCTAssertEqual(s.rp - rp0, 3000)
    }

    // 소급: coin은 전액(2,000 × N), RP는 차액(500 × N).
    func testBackfillCreditsCoinInFullAndRPDelta() {
        let s = Settings.shared
        setPRs([1, 2, 3, 4])
        let coins0 = s.coins, rp0 = s.rp

        s.applyContributorRewardV2IfNeeded()

        XCTAssertEqual(s.coins - coins0, 8000, "coin은 v0.10~ 구간에 아예 안 나갔으므로 전액")
        XCTAssertEqual(s.rp - rp0, 2000, "RP는 500 → 1,000 인상분만")
    }

    // 두 번 돌아도 한 번만 — 플래그 dedup.
    func testBackfillIsIdempotent() {
        let s = Settings.shared
        setPRs([7, 8])
        let coins0 = s.coins, rp0 = s.rp

        s.applyContributorRewardV2IfNeeded()
        let afterFirst = (coins: s.coins, rp: s.rp)
        s.applyContributorRewardV2IfNeeded()
        s.applyContributorRewardV2IfNeeded()

        XCTAssertEqual(s.coins, afterFirst.coins)
        XCTAssertEqual(s.rp, afterFirst.rp)
        XCTAssertEqual(s.coins - coins0, 4000)
        XCTAssertEqual(s.rp - rp0, 1000)
    }

    // 기여 이력이 없으면 아무것도 지급하지 않는다(플래그만 켜진다).
    func testBackfillSkipsUsersWithoutPRs() {
        let s = Settings.shared
        setPRs([])
        let coins0 = s.coins, rp0 = s.rp

        s.applyContributorRewardV2IfNeeded()

        XCTAssertEqual(s.coins, coins0)
        XCTAssertEqual(s.rp, rp0)
        XCTAssertFalse(s.rpHistory.contains { $0.reason.hasPrefix("contributor.backfill") })
    }

    /// v0.6.10 소급(50 → 1,000)의 차액은 **역사값 950으로 고정**이다. 예전처럼
    /// `coinPerContributorPR - 50`으로 계산하면 이번 인상 때문에 1,950으로 부풀어,
    /// 아직 그 플래그를 안 거친 사용자(백업 복원·재설치)가 당시 정책과 다른 금액을 받는다.
    func testLegacyUpgradeDeltaIsPinnedToItsOwnEra() {
        let s = Settings.shared
        setPRs([1, 2])
        let coins0 = s.coins

        s.applyContributorBonusUpgradeIfNeeded()

        XCTAssertEqual(s.coins - coins0, 1900, "950 × 2 — 현재 단가와 무관해야 한다")
    }
}
