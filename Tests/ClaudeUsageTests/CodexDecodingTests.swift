import XCTest
@testable import ClaudeUsage

// 이슈 #47/#50 회귀 가드 — Codex 사용량 응답 디코딩이 한 필드(특히 Pro 플랜 credits) 드리프트에
// 응답 전체를 죽이지 않고, rate_limit/plan 등 디코딩 가능한 값을 살려내는지 검증.
final class CodexDecodingTests: XCTestCase {

    // 이슈 #50 실제 캡처 기반: Pro 플랜은 rate_limit이 정상(5h+7d)이나 credits 구조가 우리 기대와
    // 달라 v0.12.0 monolithic 디코더가 응답 전체를 실패시켰다. 필드별 try? 격리로 rate_limit/plan은
    // 살고, credits는 견고화된 init이 깨진 필드만 nil로 흡수해야 한다.
    func testProResponseSalvagesRateLimitWhenCreditsDrift() throws {
        let json = """
        {
          "plan_type": "pro",
          "rate_limit": {
            "primary_window":   { "used_percent": 2,  "limit_window_seconds": 18000,  "reset_at": 1782356639, "reset_after_seconds": 9151 },
            "secondary_window": { "used_percent": 14, "limit_window_seconds": 604800, "reset_at": 1782454377, "reset_after_seconds": 106889 }
          },
          "credits": { "has_credits": "no", "balance": "0.00" }
        }
        """.data(using: .utf8)!

        let resp = try JSONDecoder().decode(CodexUsageResponse.self, from: json)

        XCTAssertEqual(resp.planType, "pro")
        let primary = try XCTUnwrap(resp.rateLimit?.primaryWindow)
        let secondary = try XCTUnwrap(resp.rateLimit?.secondaryWindow)
        XCTAssertEqual(primary.usedPercent, 2)
        XCTAssertEqual(secondary.usedPercent, 14)
        XCTAssertEqual(primary.limitWindowSeconds, 18000)   // Int→Double 흡수
        // 창 분류 — primary=5h, secondary=7d (Equatable 의존 없이 패턴 매칭으로 검증)
        if case .fiveHour = primary.kind {} else { XCTFail("primary는 5h여야 함") }
        if case .weekly   = secondary.kind {} else { XCTFail("secondary는 7d여야 함") }
        // 깨진 credits는 견고화된 CodexCredits.init이 필드별로 흡수 → 객체는 살되 깨진 필드만 nil
        XCTAssertNil(resp.credits?.balance, "string balance는 try?로 흡수되어 nil")
        XCTAssertNil(resp.credits?.hasCredits, "string has_credits는 try?로 흡수되어 nil")
    }

    // credits가 객체가 아닌 엉뚱한 컨테이너(배열/문자열)로 와도 상위 try?가 격리해 rate_limit은 보존.
    func testWrongContainerCreditsIsolatedFromRateLimit() throws {
        let json = """
        { "plan_type": "plus",
          "rate_limit": { "primary_window": { "used_percent": 7, "limit_window_seconds": 18000 } },
          "credits": "unexpected" }
        """.data(using: .utf8)!

        let resp = try JSONDecoder().decode(CodexUsageResponse.self, from: json)

        XCTAssertEqual(resp.planType, "plus")
        XCTAssertEqual(resp.rateLimit?.primaryWindow?.usedPercent, 7)
        XCTAssertNil(resp.credits, "컨테이너 타입 자체가 틀린 credits는 상위 try?로 nil 격리")
    }

    // Int→Double 완화 — 서버가 초/타임스탬프/사용률을 실수로 주더라도 디코딩 생존.
    func testFractionalWindowFieldsDecode() throws {
        let json = """
        { "rate_limit": { "primary_window": { "used_percent": 5.5, "limit_window_seconds": 18000.0, "reset_at": 1782356639.0 } } }
        """.data(using: .utf8)!

        let resp = try JSONDecoder().decode(CodexUsageResponse.self, from: json)
        XCTAssertEqual(resp.rateLimit?.primaryWindow?.usedPercent, 5.5)
        XCTAssertEqual(resp.rateLimit?.primaryWindow?.limitWindowSeconds, 18000)
        XCTAssertEqual(resp.rateLimit?.primaryWindow?.resetAt, 1782356639)
    }

    // 빈/무관 응답은 디코딩은 되지만 사용 가능 신호가 0 — refresh()의 전면 드리프트 가드 입력 조건.
    func testEmptyObjectDecodesWithNoSignal() throws {
        let resp = try JSONDecoder().decode(CodexUsageResponse.self, from: "{}".data(using: .utf8)!)
        XCTAssertNil(resp.planType)
        XCTAssertNil(resp.rateLimit)
        XCTAssertNil(resp.credits)
    }
}
