import Foundation

// ============================================================================
// Codex (OpenAI) 사용량 — 이슈 #36
// ============================================================================
//
// Cursor와 동일한 "로컬 토큰 → 비공식 HTTP 폴링" 패턴. 인증은 `~/.codex/auth.json`
// (공식 `codex login`이 생성)에서 access_token + account_id를 직접 읽는다 — Cursor의
// SQLite/JWT 대비 단순. plan은 응답의 `plan_type`로 직접 오므로 JWT 디코딩은 account_id가
// auth.json에 없을 때의 fallback으로만 쓴다.
//
// 사용량은 GET https://chatgpt.com/backend-api/wham/usage 의 rate_limit.primary/secondary
// window. **window 종류는 primary/secondary 순서가 아니라 limit_window_seconds 로 판별**한다
// (무료 계정은 primary에 7d 창만 오고 secondary=null — 순서로 5h/7d를 가정하면 틀린다).

enum CodexPlan: String, Codable, Hashable { case pro, plus, business, free, unknown
    static func from(_ raw: String?) -> CodexPlan {
        guard let r = raw?.lowercased() else { return .unknown }
        // "prolite"(2026 신규)도 pro 계열로 흡수. 순서 주의 — "pro"를 "prolite"보다 먼저 검사하지 말 것.
        if r.contains("pro") { return .pro }
        if r.contains("plus") { return .plus }
        if r.contains("business") || r.contains("team") || r.contains("enterprise") { return .business }
        if r.contains("free") || r.contains("go") || r.contains("guest") { return .free }
        return .unknown
    }
}

struct CodexSnapshot: Codable, Hashable {
    var takenAt: Date
    var plan: CodexPlan
    var planName: String?           // plan_type 원문 ("plus", "pro", "prolite" 등)
    // Plus/Pro는 5h(18000s) + 7d(604800s) 두 창을 쓰고, free는 monthly(2592000s) 단일 창만 온다
    // (실데이터 확인). 그래서 세 슬롯을 두되 한 스냅샷에 보통 최대 2개만 채워진다.
    var fiveHourPct: Double?
    var fiveHourResetAt: Date?
    var sevenDayPct: Double?
    var sevenDayResetAt: Date?
    var monthlyPct: Double?         // free 계정의 월간 창
    var monthlyResetAt: Date?
    // 부가: pay-as-you-go 크레딧 (있을 때만)
    var creditsBalance: Double?
    var hasCredits: Bool?
}

enum CodexError: Error, LocalizedError {
    case notInstalled       // ~/.codex/auth.json 없음 (미설치 또는 keyring 인증 모드)
    case notLoggedIn        // 파일은 있으나 토큰이 비어있음
    case unauthorized       // 401/403 — 토큰 만료
    case http(Int)
    case transport(Error)
    case decoding(Error)
    case unrecognizedSchema  // 200 + JSON이나 알려진 사용량 필드가 하나도 안 맞음 (전면 스키마 드리프트)

    var errorDescription: String? {
        switch self {
        case .notInstalled: return "Codex CLI 인증 파일 없음 (~/.codex/auth.json)"
        case .notLoggedIn:  return "Codex 로그인 필요 (codex login)"
        case .unauthorized: return "Codex 세션 만료 (codex login 재실행)"
        case .http(let c):  return "HTTP \(c)"
        case .transport(let e): return "네트워크 오류: \(e.localizedDescription)"
        case .decoding(let e):  return "응답 해석 오류(Codex): \(Self.decodeFailureSummary(e))"
        case .unrecognizedSchema: return "Codex 응답 형식이 변경된 것 같습니다 (사용량 필드 인식 불가)"
        }
    }
}

extension CodexError {
    /// DecodingError를 PII 없이(키 경로만) 사람이 읽을 수 있게 요약한다 — 키 이름은 스키마라 PII가
    /// 아니다. 표준 `localizedDescription`("...isn't in the correct format")은 어느 필드가 문제인지
    /// 안 알려줘 원격 진단이 불가능했다(이슈 #47). 비-JSON 응답이면 codingPath가 비어 "비-JSON" 분기로 간다.
    static func decodeFailureSummary(_ error: Error) -> String {
        guard let de = error as? DecodingError else { return error.localizedDescription }
        // 키 경로만 노출하고 Swift 메타타입(\(t))은 노출하지 않는다 — 이 문자열은 errorDescription을 거쳐
        // UI 에러 배너까지 흘러가므로 'CodexRateLimitWindow' 같은 내부 타입명이 사용자에게 새면 안 된다.
        // 경로는 codingPath(+선택 키)를 점으로 잇되, 루트(빈 경로)면 "최상위"로 표기해 빈따옴표/선행 점을 피한다.
        func joinPath(_ ctx: DecodingError.Context, appending extra: String? = nil) -> String {
            let comps = ctx.codingPath.map(\.stringValue) + (extra.map { [$0] } ?? [])
            return comps.isEmpty ? "최상위" : comps.joined(separator: ".")
        }
        switch de {
        case .typeMismatch(_, let ctx):  return "타입 불일치 '\(joinPath(ctx))'"
        case .valueNotFound(_, let ctx): return "값 누락 '\(joinPath(ctx))'"
        case .keyNotFound(let k, let ctx): return "키 없음 '\(joinPath(ctx, appending: k.stringValue))'"
        case .dataCorrupted(let ctx):
            return ctx.codingPath.isEmpty ? "최상위 JSON 파싱 실패 (비-JSON 응답 의심)"
                                          : "데이터 손상 '\(joinPath(ctx))'"
        @unknown default: return "알 수 없는 디코딩 오류"
        }
    }
}

// MARK: - wham/usage 응답 디코딩
//
// 비공식 endpoint라 모든 필드를 optional로 둬 부분적 스키마 변경에도 디코딩 자체는 살아남게 한다
// (Diagnostics가 "200인데 모든 pct nil" 같은 드리프트를 따로 잡는다).

struct CodexUsageResponse: Decodable {
    let planType: String?
    let rateLimit: CodexRateLimit?
    let credits: CodexCredits?

    enum CodingKeys: String, CodingKey {
        case planType  = "plan_type"
        case rateLimit = "rate_limit"
        case credits
    }

    // 비공식 스키마라 한 하위 필드의 타입 변경(예: 유료 플랜 응답의 credits 구조 차이)이 응답 전체
    // 디코딩을 죽이지 않도록 각 필드를 독립적으로 흡수한다 — "optional"은 키 누락만 막지 타입 불일치는
    // 막지 못한다. 최상위가 JSON object가 아닌 경우(Cloudflare HTML 등)만 throw → refresh()가 진단 로깅.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        planType  = try? c.decodeIfPresent(String.self, forKey: .planType)
        rateLimit = try? c.decodeIfPresent(CodexRateLimit.self, forKey: .rateLimit)
        credits   = try? c.decodeIfPresent(CodexCredits.self, forKey: .credits)
    }
}

struct CodexRateLimit: Decodable {
    let primaryWindow: CodexRateLimitWindow?
    let secondaryWindow: CodexRateLimitWindow?

    enum CodingKeys: String, CodingKey {
        case primaryWindow   = "primary_window"
        case secondaryWindow = "secondary_window"
    }

    // window 하나의 타입 드리프트가 다른 window까지 nil로 만들지 않도록 각각 독립 흡수.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        primaryWindow   = try? c.decodeIfPresent(CodexRateLimitWindow.self, forKey: .primaryWindow)
        secondaryWindow = try? c.decodeIfPresent(CodexRateLimitWindow.self, forKey: .secondaryWindow)
    }
}

struct CodexRateLimitWindow: Decodable {
    let usedPercent: Double?
    // 초/타임스탬프는 정수로 오지만, 서버가 실수(123.0)로 주면 Int? 디코딩이 통째로 실패한다.
    // Double?로 받아 정수·실수를 모두 흡수한다(아래 비교/환산은 어차피 TimeInterval=Double).
    let limitWindowSeconds: Double?
    let resetAfterSeconds: Double?
    let resetAt: Double?            // Unix timestamp (seconds)

    enum CodingKeys: String, CodingKey {
        case usedPercent        = "used_percent"
        case limitWindowSeconds = "limit_window_seconds"
        case resetAfterSeconds  = "reset_after_seconds"
        case resetAt            = "reset_at"
    }

    // 창 종류는 limit_window_seconds 로 판별 (primary/secondary 순서로 가정 금지 —
    // 무료 계정은 primary에 monthly만 온다). 실측: 5h=18000 / 7d=604800 / monthly=2592000.
    // 경계는 종류 사이 한참 넉넉히 둬서 값이 약간 흔들려도 같은 종류로 흡수.
    enum Kind { case fiveHour, weekly, monthly, other }
    var kind: Kind {
        guard let s = limitWindowSeconds, s > 0 else { return .other }
        switch s {
        case ..<60_000:            return .fiveHour    // ~18000 (5h)
        case 60_000..<1_500_000:   return .weekly      // ~604800 (7d)
        default:                   return .monthly     // ~2592000 (30d)
        }
    }

    /// reset_at(절대) 우선, 없으면 reset_after_seconds(상대)로 환산.
    func resetDate(now: Date) -> Date? {
        if let at = resetAt, at > 0 { return Date(timeIntervalSince1970: TimeInterval(at)) }
        if let after = resetAfterSeconds, after >= 0 { return now.addingTimeInterval(TimeInterval(after)) }
        return nil
    }
}

struct CodexCredits: Decodable {
    let hasCredits: Bool?
    let balance: Double?

    enum CodingKeys: String, CodingKey {
        case hasCredits = "has_credits"
        case balance
    }

    // Pro 플랜 등에서 has_credits/balance 타입이 우리 기대와 다르게 와도(이슈 #47/#50) credits 객체
    // 전체가 죽지 않게 필드별 try? 흡수. 상위 CodexUsageResponse.init의 `try?`와 이중 안전망이지만,
    // 이렇게 두면 credits를 nil로 통째로 버리지 않고 디코딩 가능한 필드는 보존한다.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hasCredits = try? c.decodeIfPresent(Bool.self, forKey: .hasCredits)
        balance    = try? c.decodeIfPresent(Double.self, forKey: .balance)
    }
}

// MARK: - auth.json 디코딩 (스키마 A: 공식 codex / 스키마 B: codex-oauth flat)

private struct CodexAuthFile: Decodable {
    struct Tokens: Decodable {
        let accessToken: String?
        let idToken: String?
        let accountId: String?
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case idToken     = "id_token"
            case accountId   = "account_id"
        }
    }
    let tokens: Tokens?
    // 스키마 B (7shi/codex-oauth 등): 최상위 flat
    let access: String?
    let accountIdFlat: String?
    enum CodingKeys: String, CodingKey {
        case tokens, access
        case accountIdFlat = "accountId"
    }
}

actor CodexAPI {
    static let shared = CodexAPI()

    private let usageURL = "https://chatgpt.com/backend-api/wham/usage"
    // Cursor와 동일 — 자체 UA는 봇 검출 신호. chatgpt.com 대시보드와 비슷한 Safari UA.
    private let ua = sharedBrowserUserAgent

    /// `$CODEX_HOME` 환경변수 재지정 지원, 기본 `~/.codex`.
    private var authPath: String {
        let dir = ProcessInfo.processInfo.environment["CODEX_HOME"]
            ?? "\(FileManager.default.homeDirectoryForCurrentUser.path)/.codex"
        return "\(dir)/auth.json"
    }

    func refresh() async throws -> CodexSnapshot {
        let auth = try readAuth()
        let data = try await get(access: auth.access, accountId: auth.accountId, label: "GET /wham/usage")
        let resp: CodexUsageResponse
        do {
            resp = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
        } catch {
            // PII 없이 진단: 디코딩 실패 요약 + 응답 첫 바이트("{"=JSON object / "<"=HTML 등) + 바이트 수.
            // Cloudflare/HTML 200 응답이면 first가 "{"가 아니라 typeMismatch와 구분된다(이슈 #47).
            DebugLog.log(" Codex usage 디코딩 실패: \(CodexError.decodeFailureSummary(error)) | \(Self.bodyHint(data))")
            throw CodexError.decoding(error)
        }
        let snap = toSnapshot(resp)
        // 필드별 try? 흡수는 "한 필드 타입 드리프트가 형제 필드까지 죽이는 것"만 막는다. 하지만 plan·
        // 모든 window·credits가 *전부* nil이면 = 부분 스키마(키 누락)가 아니라 전면 드리프트다. 이걸
        // .success로 흘리면 refreshCodex가 빈 스냅샷을 저장하고 apiSchemaSuspect 신호를 잃는다. throw해서
        // 기존 스키마-드리프트 감지 경로가 켜지게 한다 — 정상 응답은 plan_type+window가 있어 오탐 0.
        if snap.planName == nil, snap.fiveHourPct == nil, snap.sevenDayPct == nil,
           snap.monthlyPct == nil, snap.creditsBalance == nil, snap.hasCredits == nil {
            DebugLog.log(" Codex usage 전면 드리프트: 인식 필드 0 | \(Self.bodyHint(data))")
            throw CodexError.unrecognizedSchema
        }
        return snap
    }

    // 진단 로그용 응답 힌트 — 첫 바이트("{"=JSON / "<"=HTML)와 바이트 수만. body 본문은 PII라 안 남긴다.
    private static func bodyHint(_ data: Data) -> String {
        let first = data.first.map { String(UnicodeScalar($0)) } ?? "∅"
        return "first=\(first) bytes=\(data.count)"
    }

    // MARK: - auth.json

    /// 스키마 A/B 모두 처리. access_token은 필수, account_id는 (있으면) 헤더용.
    private func readAuth() throws -> (access: String, accountId: String?) {
        guard FileManager.default.fileExists(atPath: authPath) else { throw CodexError.notInstalled }
        guard let data = FileManager.default.contents(atPath: authPath) else { throw CodexError.notInstalled }
        let file: CodexAuthFile
        do { file = try JSONDecoder().decode(CodexAuthFile.self, from: data) }
        catch { throw CodexError.decoding(error) }

        guard let access = file.tokens?.accessToken ?? file.access, !access.isEmpty else {
            throw CodexError.notLoggedIn
        }
        // account_id: auth.json 직접 필드 우선, 없으면 JWT(id_token 우선)에서 fallback 추출.
        var accountId = file.tokens?.accountId ?? file.accountIdFlat
        if accountId == nil {
            let jwt = file.tokens?.idToken ?? access
            accountId = Self.extractAccountId(fromJWT: jwt)
        }
        return (access, accountId)
    }

    /// JWT payload에서 chatgpt_account_id를 서명 검증 없이 추출. 3단계 fallback.
    /// CursorAPI.base64URLDecode 재사용 (actor static, nonisolated).
    static func extractAccountId(fromJWT jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2,
              let data = CursorAPI.base64URLDecode(String(parts[1])),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let id = json["chatgpt_account_id"] as? String { return id }
        if let auth = json["https://api.openai.com/auth"] as? [String: Any],
           let id = auth["chatgpt_account_id"] as? String { return id }
        if let orgs = json["organizations"] as? [[String: Any]],
           let id = orgs.first?["id"] as? String { return id }
        return nil
    }

    // MARK: - HTTP

    // 운영(send)·진단(rawGet) 두 경로가 같은 헤더를 쓰도록 request 빌드를 한 곳에 둔다.
    private func buildUsageRequest(access: String, accountId: String?) -> URLRequest? {
        guard let url = URL(string: usageURL) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        if let accountId { req.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id") }
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("https://chatgpt.com", forHTTPHeaderField: "Origin")
        req.setValue("https://chatgpt.com/", forHTTPHeaderField: "Referer")
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        return req
    }

    private func get(access: String, accountId: String?, label: String) async throws -> Data {
        guard let req = buildUsageRequest(access: access, accountId: accountId) else { throw CodexError.http(-1) }
        return try await send(req, label: label)
    }

    private func send(_ req: URLRequest, label: String) async throws -> Data {
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch { throw CodexError.transport(error) }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        // body엔 plan/사용 패턴·account 정보 포함 — status/length만 로깅 (Cursor와 동일 정책).
        DebugLog.log(" Codex \(label) -> status=\(status) bytes=\(data.count)")
        if status == 401 || status == 403 { throw CodexError.unauthorized }
        if !(200..<300).contains(status) { throw CodexError.http(status) }
        return data
    }

    // MARK: - 파싱

    private func toSnapshot(_ r: CodexUsageResponse) -> CodexSnapshot {
        let now = Date()
        var five: CodexRateLimitWindow?
        var seven: CodexRateLimitWindow?
        var month: CodexRateLimitWindow?
        for w in [r.rateLimit?.primaryWindow, r.rateLimit?.secondaryWindow].compactMap({ $0 }) {
            switch w.kind {
            case .fiveHour: five = w
            case .weekly:   seven = w
            case .monthly:  month = w
            case .other:    break
            }
        }
        return CodexSnapshot(
            takenAt: now,
            plan: CodexPlan.from(r.planType),
            planName: r.planType,
            fiveHourPct: five?.usedPercent,
            fiveHourResetAt: five?.resetDate(now: now),
            sevenDayPct: seven?.usedPercent,
            sevenDayResetAt: seven?.resetDate(now: now),
            monthlyPct: month?.usedPercent,
            monthlyResetAt: month?.resetDate(now: now),
            creditsBalance: r.credits?.balance,
            hasCredits: r.credits?.hasCredits
        )
    }

    // MARK: - 로컬 진단 (--check)

    // refresh()와 같은 readAuth/get/toSnapshot 경로를 그대로 타되, throw 대신 단계별 status·raw
    // body·파싱 결과를 구조체에 담아 반환. raw body엔 plan·account 정보가 있으므로 CLI stdout 전용.
    func diagnose() async -> CodexDiagnostics {
        var d = CodexDiagnostics()
        d.authExists = FileManager.default.fileExists(atPath: authPath)
        guard d.authExists else {
            d.fatal = "~/.codex/auth.json 없음 (Codex 미설치 또는 keyring 인증 모드)"
            return d
        }
        let auth: (access: String, accountId: String?)
        do { auth = try readAuth() }
        catch {
            d.fatal = "auth.json 읽기 실패: \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
            return d
        }
        d.tokenFound = true
        d.accountIdFound = auth.accountId != nil

        let (data, status) = await rawGet(access: auth.access, accountId: auth.accountId)
        d.usageStatus = status
        d.usageRawData = data
        if let data, let resp = try? JSONDecoder().decode(CodexUsageResponse.self, from: data) {
            d.snapshot = toSnapshot(resp)
        }
        return d
    }

    // 진단 전용: send()와 달리 throw하지 않고 (data?, status) 노출. builder를 공유하므로 헤더는 운영 경로와 항상 동일.
    private func rawGet(access: String, accountId: String?) async -> (Data?, Int) {
        guard let req = buildUsageRequest(access: access, accountId: accountId) else { return (nil, -1) }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            return (data, (resp as? HTTPURLResponse)?.statusCode ?? -1)
        } catch { return (nil, -1) }
    }

    // MARK: - 파싱 검증용 익명 샘플 (이슈 #36)

    // diagnose()의 raw 응답에서 PII·민감값을 제거하고 진단용 서브트리만 추려 서버 제출 페이로드를 만든다.
    // - rate_limit: 사용률 창 구조 그대로 (식별정보 없음 — 새 필드도 보존돼야 "어떻게 오는지" 확인됨).
    // - credits: 어느 필드가 어떤 타입으로 와서 디코딩이 깨졌는지(이슈 #47/#50: Pro 플랜 credits 드리프트)
    //   확인하려면 구조(타입)가 필요하나, balance·approx 메시지수는 민감하므로 값을 타입 태그로 치환한다.
    //   타입만으로 드리프트 원인이 잡히므로 금액·카운트 원값 없이 진단 가치를 유지한다.
    // email/user_id 등은 whitelist에 없어 애초에 제외된다.
    func usageDiagnostic() async -> UsageDiagnosticExtract? {
        let d = await diagnose()
        guard d.tokenFound, let data = d.usageRawData,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var sanitized = obj
        if var credits = obj["credits"] as? [String: Any] {
            for k in ["balance", "approx_cloud_messages", "approx_local_messages"] where credits[k] != nil {
                credits[k] = Self.typeTag(credits[k]!)
            }
            sanitized["credits"] = credits
        }
        return UsageDiagnosticExtract(
            subtreeJson: DiagnosticExtract.subtreeJSON(from: sanitized, whitelist: ["rate_limit", "credits"]),
            planType: obj["plan_type"] as? String
        )
    }

    // JSON 값의 타입만 노출하는 진단 태그 — 민감 값(금액/카운트)은 지우되 "어떤 타입이 왔는지"는 보존.
    // JSONSerialization은 숫자·불리언을 모두 NSNumber로 주므로 CFBooleanGetTypeID로 둘을 구분한다.
    private static func typeTag(_ v: Any) -> String {
        switch v {
        case is NSNull: return "<null>"
        case let n as NSNumber: return CFGetTypeID(n) == CFBooleanGetTypeID() ? "<bool>" : "<number>"
        case is String: return "<string>"
        case is [Any]: return "<array>"
        case is [String: Any]: return "<object>"
        default: return "<unknown>"
        }
    }
}

struct CodexDiagnostics: Sendable {
    var authExists = false
    var tokenFound = false
    var accountIdFound = false
    var usageStatus: Int?
    var usageRawData: Data?
    var snapshot: CodexSnapshot?
    var fatal: String?
}
