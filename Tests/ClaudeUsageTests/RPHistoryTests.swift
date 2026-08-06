import XCTest
@testable import ClaudeUsage

/// RP 이력 라벨 파싱 (#192). reason 코드는 소스마다 구분자가 달라서(정산은 `.`, 이펙트 구매는 `:`)
/// 표시 문구가 조용히 "적립/사용"으로 떨어지기 쉽다 — 실제로 쓰이는 코드 형태를 고정한다.
final class RPHistoryTests: XCTestCase {

    private func label(_ amount: Int, _ reason: String) -> String {
        RPHistoryEntry(amount: amount, reason: reason).label
    }

    // 개인 정산 — ViewModel이 "rank.\(dedupKey)", dedupKey = "\(periodType).\(period).\(rank)".
    func testWeeklyAndMonthlySettlementLabels() {
        XCTAssertEqual(label(60, "rank.weekly.2026-W30.5"), "주간 정산 2026-W30 · 5위")
        XCTAssertEqual(label(200, "rank.monthly.2026-07.7"), "월간 정산 2026-07 · 7위")
        XCTAssertEqual(label(500, "rank.guild-monthly.2026-07.1"), "길드 시상 2026-07 · 1위")
    }

    // 통합 보상(grant) — grant_key가 그대로 실린다. pvp 시즌만 별도 문구.
    func testGrantLabels() {
        XCTAssertEqual(label(1500, "grant.vp-stall-2026-07"), "보상 지급")
        XCTAssertEqual(label(300, "grant.pvp-season-3"), "아레나 시즌 보상")
    }

    // 소비 — 이펙트 구매만 콜론 구분자를 쓴다. 이펙트 이름까지 살아나야 한다.
    func testSpendLabels() {
        XCTAssertEqual(label(-2000, "effect:fox:rainbow"), "이펙트 구매 · \(EffectKind.rainbow.displayName)")
        XCTAssertEqual(label(-1500, "premiumTicket"), "프리미엄 가챠권 구매")
        XCTAssertEqual(label(-300, "guild.rename"), "길드명 변경")
    }

    func testMiscLabels() {
        XCTAssertEqual(label(1500, "contributor.3PR"), "기여자 보너스")
        XCTAssertEqual(label(2000, "coffee"), "커피 후원 감사 보상")
    }

    // 미래에 새 reason이 생겨도 UI가 깨지지 않고 부호에 맞는 기본 문구로 떨어진다.
    func testUnknownReasonFallsBackBySign() {
        XCTAssertEqual(label(10, "something.new"), "적립")
        XCTAssertEqual(label(-10, "something.new"), "사용")
    }

    // 형식이 어긋난 정산 코드(필드 부족)도 크래시 없이 일반 문구로.
    func testMalformedSettlementCode() {
        XCTAssertEqual(label(60, "rank.weekly"), "순위 정산")
    }
}
