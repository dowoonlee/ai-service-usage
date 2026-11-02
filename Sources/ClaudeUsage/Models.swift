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
    /// 모델 한정 주간 한도(`limits[].kind == "weekly_scoped"`, 2026-10-30 Ultra 개편과 함께 등장).
    /// 전체 주간(`sevenDayPct`)과 별개로 Fable 같은 최상위 모델에 전체의 50%가 따로 걸린다 —
    /// 실제로 사용자를 먼저 막는 한도라 표시한다. 옛 JSONL 행엔 없으므로 셋 다 optional.
    var scopedWeeklyPct: Double?
    var scopedWeeklyResetAt: Date?
    var scopedWeeklyLabel: String?      // scope.model.display_name 원문 ("Fable")
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
    /// `limits[]` 원소. 2026-10-30 Ultra 개편과 함께 추가된 배열로, 관측된 kind는
    /// `weekly_all`(= seven_day와 같은 값)과 `weekly_scoped`(모델 한정, `scope.model.display_name`).
    struct Limit: Decodable {
        struct Scope: Decodable {
            struct Model: Decodable { let display_name: String? }
            let model: Model?
        }
        let kind: String?
        let group: String?
        let percent: Double?
        let resets_at: String?
        let is_active: Bool?
        let scope: Scope?
    }
    let five_hour: Window?
    let seven_day: Window?
    let seven_day_opus: Window?
    let seven_day_sonnet: Window?
    let extra_usage: Extra?
    let limits: [Limit]?

    private enum CodingKeys: String, CodingKey {
        case five_hour, seven_day, seven_day_opus, seven_day_sonnet, extra_usage, limits
    }

    init(five_hour: Window? = nil, seven_day: Window? = nil, seven_day_opus: Window? = nil,
         seven_day_sonnet: Window? = nil, extra_usage: Extra? = nil, limits: [Limit]? = nil) {
        self.five_hour = five_hour
        self.seven_day = seven_day
        self.seven_day_opus = seven_day_opus
        self.seven_day_sonnet = seven_day_sonnet
        self.extra_usage = extra_usage
        self.limits = limits
    }

    // 기존 창 필드는 그대로 엄격하게 둔다 — 타입 드리프트가 throw → schema-suspect 로 잡혀야 한다.
    // `limits`만 try? 로 푼다: 부가 정보라 배열 모양이 바뀌었다고 5h/7d까지 버리면 안 된다.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        five_hour = try c.decodeIfPresent(Window.self, forKey: .five_hour)
        seven_day = try c.decodeIfPresent(Window.self, forKey: .seven_day)
        seven_day_opus = try c.decodeIfPresent(Window.self, forKey: .seven_day_opus)
        seven_day_sonnet = try c.decodeIfPresent(Window.self, forKey: .seven_day_sonnet)
        extra_usage = try c.decodeIfPresent(Extra.self, forKey: .extra_usage)
        limits = try? c.decodeIfPresent([Limit].self, forKey: .limits)
    }

    /// 모델 한정 주간 한도 — 여러 개면 `is_active`인 것을 우선한다(지금 사용자를 막고 있는 한도).
    var scopedWeeklyLimit: Limit? {
        let scoped = (limits ?? []).filter { $0.kind == "weekly_scoped" }
        return scoped.first { $0.is_active == true } ?? scoped.first
    }
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
