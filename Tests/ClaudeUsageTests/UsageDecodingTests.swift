import XCTest
@testable import ClaudeUsage

/// Claude·Cursor 응답 파싱 회귀 가드.
///
/// 세 소스 모두 **비공식 엔드포인트**를 쓰는데 회귀 가드는 Codex에만 있었다(`CodexDecodingTests`).
/// 나머지 둘은 스키마가 조용히 바뀌면 배포 후 사용자 리포트로나 알 수 있는 상태였고, 그건 이
/// 앱에서 가장 자주 깨지는 종류의 변화다.
///
/// 여기 JSON은 실제 응답 형태를 옮긴 것이다. 필드가 사라지거나 타입이 바뀌는 드리프트에서
/// **살릴 수 있는 값은 살아남는지**를 본다 — 한 필드가 흔들렸다고 응답 전체를 버리면 사용자
/// 화면이 통째로 비고, 그게 Codex에서 실제로 났던 사고다(#47/#50).
final class UsageDecodingTests: XCTestCase {

    // MARK: - Claude: 사용량 응답

    func testClaudeUsageResponseDecodes() throws {
        let json = """
        {
          "five_hour":  { "utilization": 42.5, "resets_at": "2026-08-12T15:00:00Z" },
          "seven_day":  { "utilization": 18.0, "resets_at": "2026-08-18T00:00:00Z" },
          "seven_day_opus":   { "utilization": 9.5,  "resets_at": "2026-08-18T00:00:00Z" },
          "seven_day_sonnet": { "utilization": 12.0, "resets_at": "2026-08-18T00:00:00Z" },
          "extra_usage": { "is_enabled": true, "monthly_limit": 100.0, "used_credits": 23.5,
                           "utilization": 23.5, "currency": "USD" }
        }
        """.data(using: .utf8)!
        let r = try JSONDecoder().decode(APIUsageResponse.self, from: json)
        XCTAssertEqual(r.five_hour?.utilization, 42.5)
        XCTAssertEqual(r.five_hour?.resets_at, "2026-08-12T15:00:00Z")
        XCTAssertEqual(r.seven_day?.utilization, 18.0)
        XCTAssertEqual(r.extra_usage?.is_enabled, true)
        XCTAssertEqual(r.extra_usage?.used_credits, 23.5)
    }

    /// 창이 일부만 오는 계정(무료 등). 없는 창은 nil이어야 하고, 있는 창은 그대로 살아야 한다.
    func testClaudePartialWindowsSurvive() throws {
        let json = #"{"five_hour":{"utilization":5,"resets_at":"2026-08-12T15:00:00Z"}}"#
            .data(using: .utf8)!
        let r = try JSONDecoder().decode(APIUsageResponse.self, from: json)
        XCTAssertEqual(r.five_hour?.utilization, 5)
        XCTAssertNil(r.seven_day)
        XCTAssertNil(r.extra_usage)
    }

    /// 정수/실수 혼용은 흔한 드리프트다. Double로 받으므로 둘 다 통과해야 한다.
    func testClaudeIntegerUtilizationDecodes() throws {
        let json = #"{"five_hour":{"utilization":42,"resets_at":"2026-08-12T15:00:00Z"}}"#
            .data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(APIUsageResponse.self, from: json).five_hour?.utilization, 42)
    }

    /// 빈 객체도 디코딩은 되어야 한다 — 전 필드 optional이므로 throw가 아니라 nil들이 나온다.
    /// (throw가 나면 ViewModel이 schema-suspect로 분류해 오탐 알림을 띄운다.)
    func testClaudeEmptyObjectDecodes() throws {
        let r = try JSONDecoder().decode(APIUsageResponse.self, from: "{}".data(using: .utf8)!)
        XCTAssertNil(r.five_hour)
        XCTAssertNil(r.seven_day)
    }

    // MARK: - Claude: 플랜명 파생

    func testClaudePlanNameFromCapabilitiesAndTier() {
        // "Max 20x" 표기는 rate_limit_tier 접미사에서만 나온다 — capabilities엔 배수가 없다.
        XCTAssertEqual(UsageAPI.derivePlanName(capabilities: ["chat", "claude_max"],
                                               rateLimitTier: "default_claude_max_20x"), "Max 20x")
        XCTAssertEqual(UsageAPI.derivePlanName(capabilities: ["chat", "claude_max"],
                                               rateLimitTier: "default_claude_max_5x"), "Max 5x")
        XCTAssertEqual(UsageAPI.derivePlanName(capabilities: ["chat", "claude_max"],
                                               rateLimitTier: ""), "Max")
        XCTAssertEqual(UsageAPI.derivePlanName(capabilities: ["chat", "pro"], rateLimitTier: "default_pro"), "Pro")
        XCTAssertEqual(UsageAPI.derivePlanName(capabilities: ["chat", "team"], rateLimitTier: ""), "Team")
        XCTAssertEqual(UsageAPI.derivePlanName(capabilities: ["chat", "enterprise"], rateLimitTier: ""), "Enterprise")
        XCTAssertEqual(UsageAPI.derivePlanName(capabilities: ["chat"], rateLimitTier: ""), "Free")
    }

    func testClaudePlanNameIsCaseInsensitiveAndFallsBack() {
        XCTAssertEqual(UsageAPI.derivePlanName(capabilities: ["CHAT", "CLAUDE_MAX"],
                                               rateLimitTier: "DEFAULT_CLAUDE_MAX_20X"), "Max 20x")
        // 실계정 응답을 떠보니 Max 계정의 capabilities가 ["claude_max", "chat"]이었다 —
        // "chat"은 무료 표식이 아니라 모든 플랜에 붙는 공통 값이다. 그래서 미지의 등급이
        // "chat"과 함께 와도 Free로 뭉개지 않고 그 값을 살린다(코인 배수 0.5 강등 방지).
        XCTAssertEqual(UsageAPI.derivePlanName(capabilities: ["claude_ultra", "chat"],
                                               rateLimitTier: ""), "Claude_Ultra")   // capitalized는 _ 뒤도 대문자화한다
        XCTAssertEqual(UsageAPI.derivePlanName(capabilities: ["chat", "newtier"], rateLimitTier: ""), "Newtier")
        // "chat"만 있는 계정이 진짜 Free다.
        XCTAssertEqual(UsageAPI.derivePlanName(capabilities: ["chat"], rateLimitTier: ""), "Free")
        XCTAssertEqual(UsageAPI.derivePlanName(capabilities: ["newtier"], rateLimitTier: ""), "Newtier")
        XCTAssertEqual(UsageAPI.derivePlanName(capabilities: [], rateLimitTier: ""), "?")
        // 알려진 등급은 "chat"이 함께 와도 그대로 — 실계정에서 확인한 형태.
        XCTAssertEqual(UsageAPI.derivePlanName(capabilities: ["claude_max", "chat"],
                                               rateLimitTier: "default_claude_max_20x"), "Max 20x")
        // 배수가 접미사가 아니면 붙이지 않는다.
        XCTAssertEqual(UsageAPI.derivePlanName(capabilities: ["pro"], rateLimitTier: "20x_default"), "Pro")
    }

    // MARK: - Cursor: 사용량 응답

    /// 모델명이 동적 키로 오고 그 사이에 `startOfMonth`가 섞인다. 요청 수는 모델별 합, 한도는 최대값.
    func testCursorUsageAggregatesAcrossModels() throws {
        let json = """
        {
          "gpt-4": { "numRequests": 120, "maxRequestUsage": 500 },
          "claude-3.5-sonnet": { "numRequests": 30, "maxRequestUsage": 500 },
          "startOfMonth": "2026-08-01T00:00:00.000Z"
        }
        """.data(using: .utf8)!
        let snap = try CursorAPI.parseUsage(data: json, planName: "Pro", plan: .pro)
        XCTAssertEqual(snap.totalRequests, 150, "모델별 요청 수를 합산")
        XCTAssertEqual(snap.maxRequests, 500)
        XCTAssertEqual(snap.plan, .pro)
        // resetAt은 startOfMonth + 1개월. UTC 캘린더로 역산하는 쪽들과 어긋나면 월 경계가 밀린다.
        XCTAssertEqual(snap.resetAt, Date.parseISO8601("2026-09-01T00:00:00.000Z"))
    }

    /// `startOfMonth`가 없거나 형식이 바뀌어도 요청 수는 살아야 한다 — 한 필드로 전체를 버리지 않는다.
    func testCursorSurvivesMissingStartOfMonth() throws {
        let json = #"{"gpt-4":{"numRequests":7,"maxRequestUsage":100}}"#.data(using: .utf8)!
        let snap = try CursorAPI.parseUsage(data: json, planName: nil, plan: .free)
        XCTAssertEqual(snap.totalRequests, 7)
        XCTAssertNil(snap.resetAt)

        let bad = #"{"gpt-4":{"numRequests":7},"startOfMonth":"nonsense"}"#.data(using: .utf8)!
        XCTAssertEqual(try CursorAPI.parseUsage(data: bad, planName: nil, plan: .free).totalRequests, 7)
    }

    /// 모델 엔트리가 예상과 다른 모양이어도(문자열·null) 건너뛰고 나머지를 합산한다.
    func testCursorSkipsMalformedModelEntries() throws {
        let json = """
        {
          "good": { "numRequests": 5, "maxRequestUsage": 50 },
          "weird": "not-an-object",
          "nulled": null,
          "startOfMonth": "2026-08-01T00:00:00.000Z"
        }
        """.data(using: .utf8)!
        let snap = try CursorAPI.parseUsage(data: json, planName: nil, plan: .pro)
        XCTAssertEqual(snap.totalRequests, 5)
        XCTAssertEqual(snap.maxRequests, 50)
    }

    /// 최상위가 객체가 아니면(배열·문자열 등) throw — 여기서 조용히 0을 돌려주면 사용자에겐
    /// "사용량 0"으로 보이고 스키마 드리프트 감지도 못 한다.
    func testCursorThrowsOnNonObjectRoot() {
        XCTAssertThrowsError(try CursorAPI.parseUsage(data: "[]".data(using: .utf8)!,
                                                      planName: nil, plan: .pro))
        XCTAssertThrowsError(try CursorAPI.parseUsage(data: "not json".data(using: .utf8)!,
                                                      planName: nil, plan: .pro))
    }

    // MARK: - Cursor: 인증 조립

    /// JWT payload의 `sub`가 사용자 ID다. base64url(패딩 없음)을 직접 디코딩한다.
    func testCursorDecodesUserIDFromJWT() throws {
        let payload = #"{"sub":"user_01ABCDEF","exp":9999999999}"#
        let b64url = Data(payload.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let jwt = "header.\(b64url).signature"
        XCTAssertEqual(try CursorAPI.decodeUserID(jwt: jwt), "user_01ABCDEF")
    }

    func testCursorRejectsMalformedJWT() {
        XCTAssertThrowsError(try CursorAPI.decodeUserID(jwt: "only-one-part"))
        XCTAssertThrowsError(try CursorAPI.decodeUserID(jwt: "a.!!!not-base64!!!.c"))
        XCTAssertThrowsError(try CursorAPI.decodeUserID(jwt: "a.\(Data(#"{"no":"sub"}"#.utf8).base64EncodedString()).c"))
    }

    /// 쿠키는 `pctEncode(userId) + "%3A%3A" + pctEncode(jwt)` 형태다. 인코딩이 느슨해지면
    /// 쿠키가 깨져 401이 나는데, 증상이 "로그인 안 됨"이라 원인 추적이 멀어진다.
    func testCursorCookieEncodingIsStrict() {
        // JWT의 `.`과 `-`/`_`는 unreserved라 그대로 남는다.
        XCTAssertEqual(CursorAPI.pctEncode("abc.def-ghi_jkl~mno"), "abc.def-ghi_jkl~mno")
        // 그 외 기호는 전부 인코딩 — 특히 `:`(%3A)와 `/`(%2F), `+`(%2B).
        XCTAssertEqual(CursorAPI.pctEncode("a:b/c+d"), "a%3Ab%2Fc%2Bd")
        XCTAssertEqual(CursorAPI.pctEncode("user 01"), "user%2001")
    }

    func testCursorBase64URLDecodePadsCorrectly() {
        // base64url은 패딩(=)을 떼고 오므로 길이에 맞춰 되붙여야 한다.
        for raw in ["a", "ab", "abc", "abcd", "hello world!"] {
            let b64url = Data(raw.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            let decoded = CursorAPI.base64URLDecode(b64url).flatMap { String(data: $0, encoding: .utf8) }
            XCTAssertEqual(decoded, raw, "왕복 실패: \(raw)")
        }
    }
}
