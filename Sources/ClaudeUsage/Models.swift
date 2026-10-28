import Foundation

struct UsageSnapshot: Codable, Hashable {
    var takenAt: Date
    var fiveHourPct: Double?
    var fiveHourResetAt: Date?
    var sevenDayPct: Double?
    var sevenDayResetAt: Date?
    var planName: String?      // "Max 20x" 같은 정리된 표시명
    var extraUsageEnabled: Bool?
    var extraUsageUtilPct: Double?
    var extraUsageMonthlyLimit: Double?
    var extraUsageUsedCredits: Double?
}

struct APIOrganization: Decodable {
    let uuid: String
    let name: String?
    let capabilities: [String]
    let rateLimitTier: String

    private enum CodingKeys: String, CodingKey {
        case uuid, name, capabilities
        case rateLimitTier = "rate_limit_tier"
    }

    init(uuid: String, name: String? = nil, capabilities: [String] = [], rateLimitTier: String = "") {
        self.uuid = uuid
        self.name = name
        self.capabilities = capabilities
        self.rateLimitTier = rateLimitTier
    }

    // uuid 외 필드는 try? 로 푼다. capabilities 타입이 바뀌어도 org 목록 전체가 디코드 실패하면
    // 안 된다. uuid 만 있으면 usage 조회는 할 수 있다.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        capabilities = (try? c.decodeIfPresent([String].self, forKey: .capabilities)) ?? []
        rateLimitTier = (try? c.decodeIfPresent(String.self, forKey: .rateLimitTier)) ?? ""
    }
}

struct APIUsageResponse: Decodable {
    struct Window: Decodable {
        let utilization: Double?
        let resets_at: String?
    }
    struct Extra: Decodable {
        let is_enabled: Bool?
        let monthly_limit: Double?
        let used_credits: Double?
        let utilization: Double?
        let currency: String?
    }
    let five_hour: Window?
    let seven_day: Window?
    let seven_day_opus: Window?
    let seven_day_sonnet: Window?
    let extra_usage: Extra?
}

enum UsageError: Error, LocalizedError {
    case notLoggedIn
    case unauthorized
    case noOrganization
    case http(Int)
    case transport(Error)
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn: return "로그인되지 않음"
        case .unauthorized: return "세션 만료 (재로그인 필요)"
        case .noOrganization: return "조직 정보를 찾을 수 없음"
        case .http(let code): return "HTTP \(code)"
        case .transport(let e): return "네트워크 오류: \(e.localizedDescription)"
        case .decoding(let e): return "응답 해석 오류(Claude): \(e.localizedDescription)"
        }
    }
}
