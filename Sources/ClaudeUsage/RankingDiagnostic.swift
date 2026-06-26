import Foundation

/// 랭킹 응답 디코딩 실패 시 캡처한 raw 페이로드 한 조각 (#56).
///
/// `RankingAPI.execute` 가 디코딩 실패 *순간* 의 응답을 마스킹·캡해 `RankingDiagnosticStore` 에
/// 저장하고, 버그리포트 "사용량 이슈" 제출 시 최근 실패를 진단 샘플에 첨부한다. #54 처럼
/// `LeaderboardResponse` 디코딩이 깨지는 케이스에서 "실제로 깨진 페이로드" 를 확보하기 위함.
struct RankingDecodeFailure: Codable, Sendable {
    let path: String          // 엔드포인트 (leaderboard/board 등 — URL lastPathComponent)
    let status: Int           // HTTP status (보통 200인데 본문 스키마가 어긋난 케이스)
    let errorDesc: String     // DecodingError localizedDescription
    let maskedJson: String    // PII 마스킹 + 용량 캡이 적용된 응답 (항상 valid JSON 문자열)
    let capturedAt: Date
}

/// 최근 1건의 랭킹 디코딩 실패를 UserDefaults 에 보관(덮어씀). 앱 재실행에도 살아남아
/// "업데이트 후 재현되면 회신" 사각지대를 없앤다(#56). 첨부는 최근성 윈도 안쪽만.
enum RankingDiagnosticStore {
    private static let key = "ranking.lastDecodeFailure"
    /// 오래된 무관한 실패가 엉뚱한 버그리포트에 딸려가지 않도록 첨부는 이 윈도 안쪽만.
    static let attachWindow: TimeInterval = 24 * 3600

    static func record(_ f: RankingDecodeFailure) {
        guard let data = try? JSONEncoder().encode(f) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func load() -> RankingDecodeFailure? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(RankingDecodeFailure.self, from: data)
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }

    /// 첨부 후보 — 최근성 윈도(`attachWindow`) 안의 실패만 돌려준다.
    static func recentForAttach(now: Date) -> RankingDecodeFailure? {
        guard let f = load(), now.timeIntervalSince(f.capturedAt) <= attachWindow else { return nil }
        return f
    }
}

/// 랭킹 raw 응답을 PII 마스킹 + 용량 캡해 **항상 valid JSON 문자열** 로 만든다.
enum RankingResponseMask {
    /// 값만 가리고 *타입은 보존* 한다 — 랭킹 디코딩 실패는 대개 타입/형태 불일치라 타입을 남겨야
    /// 원인이 보인다(예: `coins` 가 number 대신 string 으로 와서 실패 → string "***" 로 남겨 단서 유지).
    /// 사용량 진단과 동일 정책: 닉네임·deviceId·코인·복구코드·본문 등 식별/민감 값을 제거.
    private static let piiKeys: Set<String> = [
        "nickname", "device_id", "deviceid", "recovery_code", "recoverycode",
        "github_login", "githublogin", "github", "email",
        "content", "message", "podium_message", "podiummessage", "author",
        "coins", "coin", "balance",
    ]

    /// data → 마스킹된 valid JSON 문자열.
    /// 1순위: JSON 으로 파싱돼 마스킹·캡 안쪽이면 그 객체 JSON.
    /// 폴백: 비-JSON 이거나 캡 초과면 마스킹이 불가하므로 raw 앞부분만 작게 잘라 JSON 문자열 리터럴로
    ///       (서버 `parseJsonCapped` 가 jsonb 문자열로 저장 — 깨진 페이로드의 형태라도 남긴다).
    static func maskedJSON(from data: Data, maxBytes: Int = 6000) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) {
            let masked = mask(obj)
            if JSONSerialization.isValidJSONObject(masked),
               let out = try? JSONSerialization.data(withJSONObject: masked, options: [.sortedKeys]),
               out.count <= maxBytes,
               let s = String(data: out, encoding: .utf8) {
                return s
            }
        }
        let raw = String(data: data, encoding: .utf8) ?? ""
        let capped = String(raw.prefix(max(0, maxBytes / 4)))
        return jsonStringLiteral(capped)
    }

    private static func mask(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in dict {
                let isContainer = v is [String: Any] || v is [Any]
                // PII 키의 스칼라 값만 가린다. 컨테이너면 재귀해 안쪽 PII(예: likers[].deviceId)까지 처리.
                if piiKeys.contains(k.lowercased()), !isContainer {
                    out[k] = redactScalar(v)
                } else {
                    out[k] = mask(v)
                }
            }
            return out
        }
        if let arr = value as? [Any] { return arr.map { mask($0) } }
        return value
    }

    /// 스칼라 PII 값을 타입 보존하며 가린다(String→"***", Number→0, Bool→false, null 유지).
    private static func redactScalar(_ v: Any) -> Any {
        if v is NSNull { return v }
        if let n = v as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return false }  // Bool 도 NSNumber 라 구분
            return 0
        }
        return "***"
    }

    /// 임의 문자열을 valid JSON 문자열 리터럴로(이스케이프 포함). `[s]` 직렬화 후 대괄호만 벗겨
    /// 버전 무관하게 안전하게 escape 한다(JSONEncoder 의 top-level fragment 지원 편차 회피).
    private static func jsonStringLiteral(_ s: String) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: [s]),
              let arr = String(data: d, encoding: .utf8),
              arr.hasPrefix("["), arr.hasSuffix("]") else { return "\"\"" }
        return String(arr.dropFirst().dropLast())
    }
}
