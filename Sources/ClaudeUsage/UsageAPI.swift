import Foundation

actor UsageAPI {
    static let shared = UsageAPI()

    private let base = URL(string: "https://claude.ai")!
    private let ua = sharedBrowserUserAgent
    private var cachedOrgID: String?
    private var cachedPlanName: String?
    private var cachedSessionKey: String?

    private func currentSessionKey() -> String? {
        if let k = cachedSessionKey { return k }
        let k = Keychain.load()
        cachedSessionKey = k
        return k
    }

    func invalidateSession() {
        cachedSessionKey = nil
        cachedOrgID = nil
        cachedPlanName = nil
    }

    private func session(for sessionKey: String) -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpShouldSetCookies = true
        cfg.httpCookieAcceptPolicy = .always
        let cookie = HTTPCookie(properties: [
            .domain: ".claude.ai",
            .path: "/",
            .name: "sessionKey",
            .value: sessionKey,
            .secure: true,
            .expires: Date().addingTimeInterval(60 * 60 * 24 * 365),
        ])
        if let cookie { cfg.httpCookieStorage?.setCookie(cookie) }
        cfg.httpAdditionalHeaders = [
            "User-Agent": ua,
            "Accept": "application/json, text/plain, */*",
            "Referer": "https://claude.ai/",
        ]
        return URLSession(configuration: cfg)
    }

    func refresh() async throws -> UsageSnapshot {
        guard let key = currentSessionKey(), !key.isEmpty else {
            throw UsageError.notLoggedIn
        }
        let sess = session(for: key)
        let orgID = try await resolveOrgID(sess: sess)
        let usage = try await fetchUsage(sess: sess, orgID: orgID)
        var snap = toSnapshot(usage)
        snap.planName = cachedPlanName
        return snap
    }

    private func resolveOrgID(sess: URLSession) async throws -> String {
        if let cached = cachedOrgID { return cached }
        let url = base.appendingPathComponent("api/organizations")
        let (data, resp) = try await get(sess: sess, url: url)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        // body는 organization uuid·billing·capabilities를 포함 — 평문 로그 + BugReport
        // GitHub Issue 첨부 동선에 노출되지 않게 status/length만 기록.
        DebugLog.log(" GET /api/organizations -> status=\(status) bytes=\(data.count)")
        try assertOK(resp)
        do {
            let orgs = try JSONDecoder().decode([APIOrganization].self, from: data)
            guard let first = orgs.first else { throw UsageError.noOrganization }
            cachedOrgID = first.uuid

            // 원시 JSON에서 capabilities / rate_limit_tier 추출해 plan 이름 구성
            if let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
               let org0 = raw.first {
                let caps = (org0["capabilities"] as? [String]) ?? []
                let tier = (org0["rate_limit_tier"] as? String) ?? ""
                cachedPlanName = derivePlanName(capabilities: caps, rateLimitTier: tier)
            }
            return first.uuid
        } catch let e as UsageError { throw e }
        catch { throw UsageError.decoding(error) }
    }

    private func derivePlanName(capabilities: [String], rateLimitTier: String) -> String {
        let capSet = Set(capabilities.map { $0.lowercased() })
        let base: String
        if capSet.contains("claude_max") { base = "Max" }
        else if capSet.contains("pro") { base = "Pro" }
        else if capSet.contains("team") { base = "Team" }
        else if capSet.contains("enterprise") { base = "Enterprise" }
        else if capSet.contains("chat") { base = "Free" }
        else { base = capabilities.first(where: { $0 != "chat" })?.capitalized ?? "?" }

        // "default_claude_max_20x" → "20x" 추출
        let tier = rateLimitTier.lowercased()
        if let range = tier.range(of: #"(\d+x)$"#, options: .regularExpression) {
            return "\(base) \(tier[range])"
        }
        return base
    }

    private func fetchUsage(sess: URLSession, orgID: String) async throws -> APIUsageResponse {
        let url = base.appendingPathComponent("api/organizations/\(orgID)/usage")
        let (data, resp) = try await get(sess: sess, url: url)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        // orgID 자체도 식별자라 로그에서 마스킹 (앞 8자만).
        let maskedOrg = orgID.prefix(8) + "…"
        DebugLog.log(" GET /api/organizations/\(maskedOrg)/usage -> status=\(status) bytes=\(data.count)")
        try assertOK(resp)
        do {
            return try JSONDecoder().decode(APIUsageResponse.self, from: data)
        } catch { throw UsageError.decoding(error) }
    }

    private func get(sess: URLSession, url: URL) async throws -> (Data, URLResponse) {
        do { return try await sess.data(from: url) }
        catch { throw UsageError.transport(error) }
    }

    private func assertOK(_ resp: URLResponse) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        if http.statusCode == 401 || http.statusCode == 403 {
            cachedOrgID = nil
            cachedSessionKey = nil
            throw UsageError.unauthorized
        }
        if !(200..<300).contains(http.statusCode) {
            throw UsageError.http(http.statusCode)
        }
    }

    func clearOrgCache() { cachedOrgID = nil }

    private func toSnapshot(_ r: APIUsageResponse) -> UsageSnapshot {
        return UsageSnapshot(
            takenAt: Date(),
            fiveHourPct: r.five_hour?.utilization,
            fiveHourResetAt: Date.parseISO8601(r.five_hour?.resets_at),
            sevenDayPct: r.seven_day?.utilization,
            sevenDayResetAt: Date.parseISO8601(r.seven_day?.resets_at),
            extraUsageEnabled: r.extra_usage?.is_enabled,
            extraUsageUtilPct: r.extra_usage?.utilization,
            extraUsageMonthlyLimit: r.extra_usage?.monthly_limit,
            extraUsageUsedCredits: r.extra_usage?.used_credits
        )
    }

    // MARK: - 로컬 진단 (--check)

    // refresh()와 같은 session/derivePlanName/toSnapshot 경로를 그대로 타되, throw 대신
    // 단계별 status·raw body·파싱 결과를 구조체에 담아 반환한다. 캐시는 무시하고 매번 fresh.
    // raw body엔 org uuid·capabilities가 들어있으므로 CLI stdout 전용 — BugReport 경로엔 안 쓴다.
    func diagnose() async -> ClaudeDiagnostics {
        var d = ClaudeDiagnostics()
        guard let key = currentSessionKey(), !key.isEmpty else {
            d.fatal = "로그인 안 됨 — Keychain에 sessionKey 없음 (GUI 앱에서 1회 로그인 필요)"
            return d
        }
        d.loggedIn = true
        let sess = session(for: key)

        let orgURL = base.appendingPathComponent("api/organizations")
        let (orgData, orgStatus) = await rawGet(sess: sess, url: orgURL)
        d.orgStatus = orgStatus
        d.orgRawData = orgData
        if let orgData,
           let orgs = try? JSONDecoder().decode([APIOrganization].self, from: orgData),
           let first = orgs.first {
            d.orgID = first.uuid
            if let raw = try? JSONSerialization.jsonObject(with: orgData) as? [[String: Any]],
               let org0 = raw.first {
                let caps = (org0["capabilities"] as? [String]) ?? []
                let tier = (org0["rate_limit_tier"] as? String) ?? ""
                d.planName = derivePlanName(capabilities: caps, rateLimitTier: tier)
            }
        }
        guard let orgID = d.orgID else {
            d.fatal = "조직 ID를 파싱하지 못함 (organizations 응답을 --raw로 확인)"
            return d
        }

        let usageURL = base.appendingPathComponent("api/organizations/\(orgID)/usage")
        let (usageData, usageStatus) = await rawGet(sess: sess, url: usageURL)
        d.usageStatus = usageStatus
        d.usageRawData = usageData
        if let usageData,
           let r = try? JSONDecoder().decode(APIUsageResponse.self, from: usageData) {
            var snap = toSnapshot(r)
            snap.planName = d.planName
            d.snapshot = snap
        }
        return d
    }

    // 진단 전용: 실제 get()과 달리 throw하지 않고 (data?, status)를 그대로 노출한다.
    private func rawGet(sess: URLSession, url: URL) async -> (Data?, Int) {
        do {
            let (data, resp) = try await sess.data(from: url)
            return (data, (resp as? HTTPURLResponse)?.statusCode ?? -1)
        } catch {
            return (nil, -1)
        }
    }
}

struct ClaudeDiagnostics: Sendable {
    var loggedIn = false
    var orgStatus: Int?
    var orgRawData: Data?
    var orgID: String?
    var planName: String?
    var usageStatus: Int?
    var usageRawData: Data?
    var snapshot: UsageSnapshot?
    var fatal: String?   // 더 진행할 수 없게 만든 치명적 사유 (있으면 그 단계에서 중단)
}
