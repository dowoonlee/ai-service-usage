import Foundation

actor UsageAPI {
    static let shared = UsageAPI()

    private let base = URL(string: "https://claude.ai")!
    private let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
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
        let preview = String(data: data.prefix(600), encoding: .utf8) ?? "<binary>"
        DebugLog.log(" GET /api/organizations -> status=\(status) body=\(preview)")
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
        let preview = String(data: data.prefix(1200), encoding: .utf8) ?? "<binary>"
        DebugLog.log(" GET /api/organizations/\(orgID)/usage -> status=\(status) body=\(preview)")
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
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoNoFrac = ISO8601DateFormatter()
        isoNoFrac.formatOptions = [.withInternetDateTime]
        func parse(_ s: String?) -> Date? {
            guard let s else { return nil }
            return iso.date(from: s) ?? isoNoFrac.date(from: s)
        }
        return UsageSnapshot(
            takenAt: Date(),
            fiveHourPct: r.five_hour?.utilization,
            fiveHourResetAt: parse(r.five_hour?.resets_at),
            sevenDayPct: r.seven_day?.utilization,
            sevenDayResetAt: parse(r.seven_day?.resets_at),
            extraUsageEnabled: r.extra_usage?.is_enabled,
            extraUsageUtilPct: r.extra_usage?.utilization,
            extraUsageMonthlyLimit: r.extra_usage?.monthly_limit,
            extraUsageUsedCredits: r.extra_usage?.used_credits
        )
    }
}
