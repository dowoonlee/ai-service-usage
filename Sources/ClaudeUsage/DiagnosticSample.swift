import Foundation

/// 진단 샘플 통합 페이로드 — `codex-sample` Edge Function 으로 POST (이슈 #36 + 버그리포트 통합).
///
/// 한 구조로 두 origin 을 표현한다:
///   - `codex_voluntary`: Codex 섹션 "진단 제출" 버튼. rateLimitJson + parsed + rawTopKeys (단일 소스).
///   - `bug_report`: 버그리포트 "사용량 이슈" 템플릿. 다중 소스 서브트리(rate/claude/cursor) + logTail.
///
/// raw 는 PII(email/user_id/org uuid)·잔액(credits/cost)을 제거한 **사용률 서브트리**만 담는다.
/// GitHub 공개 이슈에는 `id`(UUID)만 적고, 실제 raw 는 이 페이로드로 비공개 DB 에만 보낸다.
struct DiagnosticSample: Encodable, Sendable {
    let id: String                  // 클라 생성 UUID(소문자). GitHub 이슈 역참조 키.
    let origin: String              // "codex_voluntary" | "bug_report"
    var category: String?           // bug_report 세분류 (예: "usage")
    var deviceId: String?
    var appVersion: String?
    var osVersion: String?
    var planType: String?
    var rateLimitJson: String?      // Codex rate_limit 서브트리
    var claudeUsageJson: String?    // Claude usage 사용률 서브트리
    var cursorUsageJson: String?    // Cursor usage 사용률 서브트리
    var parsed: Parsed?             // codex_voluntary 의 파서 결과 (원본 대조용)
    var rawTopKeys: [String]?       // codex_voluntary 의 응답 최상위 키
    var logTail: String?            // 디버그 로그 마지막 N줄 (bug_report, 첨부 동의 시)
    var rankingResponseJson: String? // 랭킹 디코딩 실패 시 캡처한 마스킹 응답 (#56, valid JSON 문자열)
    var rankingDecodeError: String?  // 위 캡처 컨텍스트: "path=… status=… err=…"

    struct Parsed: Encodable, Sendable {
        let fiveHourPct: Double?
        let sevenDayPct: Double?
        let monthlyPct: Double?
    }

    /// 새 UUID 를 발급해 빈 bug_report 샘플의 골격을 만든다. 각 소스 서브트리는 호출 측에서 채운다.
    static func newBugReport(deviceId: String?, appVersion: String?, osVersion: String?) -> DiagnosticSample {
        DiagnosticSample(
            id: UUID().uuidString.lowercased(),
            origin: "bug_report",
            category: "usage",
            deviceId: deviceId,
            appVersion: appVersion,
            osVersion: osVersion,
            planType: nil,
            rateLimitJson: nil,
            claudeUsageJson: nil,
            cursorUsageJson: nil,
            parsed: nil,
            rawTopKeys: nil,
            logTail: nil,
            rankingResponseJson: nil,
            rankingDecodeError: nil
        )
    }
}

/// 각 API actor 가 버그리포트용으로 추출한 PII-free 사용률 서브트리 한 조각.
struct UsageDiagnosticExtract: Sendable {
    let subtreeJson: String?
    let planType: String?
}

enum DiagnosticExtract {
    /// 응답 raw 객체에서 PII-free 서브트리 JSON 문자열을 만든다.
    /// - `whitelist` 가 주어지면 그 키만 남긴다 (Claude/Codex — 식별정보가 섞인 최상위에서 사용률 창만).
    /// - `whitelist` 가 nil 이면 통째로 담는다 (Cursor — /api/usage 는 요청수만, cost 없음).
    /// 두 경우 모두 `_top_keys`(전체 최상위 키)를 곁들여 스키마 드리프트 감지를 보존한다.
    static func subtreeJSON(from obj: [String: Any], whitelist: [String]?) -> String? {
        var out: [String: Any] = ["_top_keys": obj.keys.sorted()]
        if let whitelist {
            for k in whitelist where obj[k] != nil { out[k] = obj[k]! }
        } else {
            for (k, v) in obj { out[k] = v }
        }
        guard JSONSerialization.isValidJSONObject(out),
              let data = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }
}
