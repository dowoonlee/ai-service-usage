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

        if let orgID = cachedOrgID {
            do {
                return snapshot(try await fetchUsage(sess: sess, orgID: orgID))
            } catch is OrgUsageForbidden {
                // 캐시한 org 의 403 만으로는 세션 만료인지 org 권한 문제인지 구분할 수 없다.
                // org 목록을 다시 받는다. 세션이 만료됐다면 그 요청이 401/403 으로 unauthorized 를 던진다.
                cachedOrgID = nil
            }
        }

        let orgs = try await fetchOrganizations(sess: sess)
        for org in Self.usageCandidates(orgs) {
            let usage: APIUsageResponse
            do {
                usage = try await fetchUsage(sess: sess, orgID: org.uuid)
            } catch is OrgUsageForbidden {
                continue
            }
            cachedOrgID = org.uuid
            cachedPlanName = Self.derivePlanName(capabilities: org.capabilities, rateLimitTier: org.rateLimitTier)
            return snapshot(usage)
        }
        // org 목록은 200 이었으므로 세션은 유효하다. 로그아웃(unauthorized)이 아니라 조직 없음으로 보고한다.
        DebugLog.log(" Claude: usage 를 허용하는 조직 없음 (orgs=\(orgs.count))")
        throw UsageError.noOrganization
    }

    private func snapshot(_ usage: APIUsageResponse) -> UsageSnapshot {
        var snap = toSnapshot(usage)
        snap.planName = cachedPlanName
        return snap
    }

    private func fetchOrganizations(sess: URLSession) async throws -> [APIOrganization] {
        let url = base.appendingPathComponent("api/organizations")
        let (data, resp) = try await get(sess: sess, url: url)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        // body는 organization uuid·billing·capabilities를 포함 — 평문 로그 + BugReport
        // GitHub Issue 첨부 동선에 노출되지 않게 status/length만 기록.
        DebugLog.log(" GET /api/organizations -> status=\(status) bytes=\(data.count)")
        try assertOK(resp)
        let orgs: [APIOrganization]
        do {
            orgs = try JSONDecoder().decode([APIOrganization].self, from: data)
        } catch { throw UsageError.decoding(error) }
        guard !orgs.isEmpty else { throw UsageError.noOrganization }
        return orgs
    }

    /// usage 를 조회해 볼 org 순서.
    ///
    /// `/api/organizations` 는 계정이 속한 org 를 전부 준다. API 콘솔 org, 팀 org 처럼 claude.ai 구독
    /// 사용량이 없는 org 가 배열 앞에 올 수 있고, 그 org 의 `/usage` 는 403 을 준다.
    /// 그래서 `chat` capability 가 있는 org 를 앞에 두고, 그 안에서는 응답 순서를 유지한다.
    ///
    /// ⚠️ `chat` org 끼리 유료 플랜을 앞으로 올리지 않는다. 개인 Free + 팀 좌석처럼 둘 다 200 을 주는
    /// 계정은 예전부터 응답 첫 org 를 추적해 왔는데, 순서를 바꾸면 업데이트 직후 추적 대상과 플랜명,
    /// `CoinLedger.planMultiplier` 가 함께 바뀐다. 이 정렬은 403 org 를 피하는 용도로만 쓴다.
    ///
    /// `chat` 이 없는 org 도 버리지 않고 맨 뒤에 둔다. capability 이름이 바뀌어도 순서만 밀릴 뿐
    /// 조회 대상에서 빠지지 않게 하기 위해서다.
    nonisolated static func usageCandidates(_ orgs: [APIOrganization]) -> [APIOrganization] {
        func rank(_ org: APIOrganization) -> Int {
            org.capabilities.contains { $0.lowercased() == "chat" } ? 0 : 1
        }
        return orgs.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }

    /// capabilities + rate_limit_tier → 표시용 플랜명. `nonisolated static`인 것은 테스트가
    /// actor 밖에서 직접 부르기 위해서다 — 인스턴스 상태를 쓰지 않으므로 격리가 필요 없다.
    nonisolated static func derivePlanName(capabilities: [String], rateLimitTier: String) -> String {
        let capSet = Set(capabilities.map { $0.lowercased() })
        let base: String
        if capSet.contains("claude_max") { base = "Max" }
        else if capSet.contains("pro") { base = "Pro" }
        else if capSet.contains("team") { base = "Team" }
        else if capSet.contains("enterprise") { base = "Enterprise" }
        // ⚠️ "chat"을 Free 판정에 쓰기 **전에** 미지의 등급을 먼저 살린다.
        //
        // 실계정 응답을 떠보니 Max 계정의 capabilities가 `["claude_max", "chat"]`이었다 —
        // "chat"은 무료 표식이 아니라 모든 플랜에 붙는 공통 값이다. 그래서 "chat이 있으면 Free"를
        // 먼저 두면, Anthropic이 새 등급 문자열(예: claude_ultra)을 추가하는 순간 그 사용자가
        // Free로 떨어지고 CoinLedger.planMultiplier까지 0.5로 깎인다.
        //
        // 모르는 값은 그대로 표시한다: 사용자가 화면에서 보고 리포트할 수 있고, planMultiplier도
        // 매칭 실패 시 기본 1.0이라 Free(0.5)보다 손해가 없다. "chat"만 있는 계정이 진짜 Free다.
        else if let unknown = capabilities.first(where: { $0.lowercased() != "chat" }) {
            base = unknown.capitalized
        }
        else if capSet.contains("chat") { base = "Free" }
        else { base = "?" }

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
        // 403 은 이 org 에 usage 권한이 없다는 뜻일 수 있다. 호출부가 다른 org 를 시도하도록
        // unauthorized 와 구분해서 던진다. 401 은 그대로 세션 만료로 본다.
        if status == 403 { throw OrgUsageForbidden() }
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
        guard let orgData,
              let orgs = try? JSONDecoder().decode([APIOrganization].self, from: orgData),
              !orgs.isEmpty else {
            d.fatal = "조직 ID를 파싱하지 못함 (organizations 응답을 --raw로 확인)"
            return d
        }

        // refresh() 와 같은 순서로 시도하되, 첫 성공에서 멈추지 않고 전부 조회해 org 별 결과를 남긴다.
        for org in Self.usageCandidates(orgs) {
            let usageURL = base.appendingPathComponent("api/organizations/\(org.uuid)/usage")
            let (usageData, usageStatus) = await rawGet(sess: sess, url: usageURL)
            let planName = Self.derivePlanName(capabilities: org.capabilities, rateLimitTier: org.rateLimitTier)
            d.orgProbes.append(ClaudeOrgProbe(
                maskedID: String(org.uuid.prefix(8)) + "…",
                capabilities: org.capabilities,
                rateLimitTier: org.rateLimitTier,
                planName: planName,
                usageStatus: usageStatus
            ))
            guard d.orgID == nil, usageStatus != 403 else { continue }
            d.orgID = org.uuid
            d.planName = planName
            d.usageStatus = usageStatus
            d.usageRawData = usageData
            if let usageData,
               let r = try? JSONDecoder().decode(APIUsageResponse.self, from: usageData) {
                var snap = toSnapshot(r)
                snap.planName = planName
                d.snapshot = snap
            }
        }
        if d.orgID == nil {
            d.fatal = "usage 를 허용하는 조직 없음 (모든 조직이 403)"
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

    // 버그리포트 "사용량 이슈"용 PII-free 추출 — 사용률 창(five_hour/seven_day/extra_usage)만
    // 화이트리스트로 떼어 org uuid·capabilities 가 섞인 최상위에서 식별정보를 배제한다.
    func usageDiagnostic() async -> UsageDiagnosticExtract? {
        let d = await diagnose()
        guard d.loggedIn, let data = d.usageRawData,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return UsageDiagnosticExtract(
            subtreeJson: DiagnosticExtract.subtreeJSON(from: obj, whitelist: ["five_hour", "seven_day", "extra_usage"]),
            planType: d.planName
        )
    }
}

/// org 의 `/usage` 가 403 일 때 던진다. 세션 만료(`UsageError.unauthorized`)와 달리
/// 다음 org 를 시도하라는 신호라 actor 밖으로 나가지 않는다.
private struct OrgUsageForbidden: Error {}

struct ClaudeOrgProbe: Sendable {
    var maskedID: String
    var capabilities: [String]
    var rateLimitTier: String
    var planName: String
    var usageStatus: Int
}

struct ClaudeDiagnostics: Sendable {
    var loggedIn = false
    var orgStatus: Int?
    var orgRawData: Data?
    var orgProbes: [ClaudeOrgProbe] = []
    var orgID: String?
    var planName: String?
    var usageStatus: Int?
    var usageRawData: Data?
    var snapshot: UsageSnapshot?
    var fatal: String?   // 더 진행할 수 없게 만든 치명적 사유 (있으면 그 단계에서 중단)
}
