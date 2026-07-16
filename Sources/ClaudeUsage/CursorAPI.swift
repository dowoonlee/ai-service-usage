import Foundation
import SQLite3

struct CursorEvent: Codable, Hashable {
    var timestamp: Date
    var model: String?
    var chargedCents: Double
}

enum CursorPlan: String, Codable { case ultra, pro, free, business, unknown
    static func from(_ raw: String?) -> CursorPlan {
        guard let r = raw?.lowercased() else { return .unknown }
        if r.contains("ultra") { return .ultra }
        if r.contains("pro") { return .pro }
        if r.contains("business") || r.contains("team") { return .business }
        if r.contains("free") { return .free }
        return .unknown
    }
}

struct CursorSnapshot: Codable, Hashable {
    var takenAt: Date
    var plan: CursorPlan
    var planName: String?          // stripeMembershipType 원문
    var resetAt: Date?

    // Pro/Free 계열 (request 기반)
    var totalRequests: Int?
    var maxRequests: Int?

    // Ultra 계열 (달러 기반)
    var totalCents: Double?        // 현재까지 누적
    var maxCents: Double?          // 월 한도 (Ultra = 40000 cents = $400)
}

enum CursorError: Error, LocalizedError {
    case cursorNotInstalled
    case notLoggedIn
    case tokenRead(String)
    case unauthorized
    case http(Int)
    case transport(Error)
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .cursorNotInstalled: return "Cursor 앱이 설치돼 있지 않음"
        case .notLoggedIn: return "Cursor 로그인 필요"
        case .tokenRead(let s): return "토큰 읽기 실패: \(s)"
        case .unauthorized: return "Cursor 세션 만료"
        case .http(let c): return "HTTP \(c)"
        case .transport(let e): return "네트워크 오류: \(e.localizedDescription)"
        case .decoding(let e): return "응답 해석 오류(Cursor): \(e.localizedDescription)"
        }
    }
}

actor CursorAPI {
    static let shared = CursorAPI()

    private let dbPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
    }()
    // 'ClaudeUsage/1.0' 같은 자체 UA는 비-브라우저 자동화 신호로 분류돼 ban-risk 가
    // 높음. 사용자가 cursor.com 대시보드를 열 때 보내는 것과 비슷한 Safari UA로 통일.
    private let ua = sharedBrowserUserAgent

    func refresh() async throws -> CursorSnapshot {
        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw CursorError.cursorNotInstalled
        }
        let jwt = try readAccessToken()
        guard !jwt.isEmpty else { throw CursorError.notLoggedIn }
        let userId = try decodeUserID(jwt: jwt)
        let planName = readString(key: "cursorAuth/stripeMembershipType")
        let plan = CursorPlan.from(planName)
        let cookie = "\(pctEncode(userId))%3A%3A\(pctEncode(jwt))"

        // /api/usage — startOfMonth(리셋 기준)와 Pro용 request 수를 한 번에 얻음
        let usageData = try await get("https://cursor.com/api/usage?user=\(pctEncode(userId))", cookie: cookie, label: "GET /api/usage")
        let base = try parseUsage(data: usageData, planName: planName, plan: plan)

        if plan == .ultra {
            // Ultra는 모델별 센트 단위 집계 엔드포인트를 추가로 호출
            let aggData = try await postJSON(
                "https://cursor.com/api/dashboard/get-aggregated-usage-events",
                cookie: cookie, body: "{}",
                label: "POST /api/dashboard/get-aggregated-usage-events"
            )
            let cents = parseAggregatedCents(data: aggData)
            var snap = base
            snap.totalCents = cents
            snap.maxCents = 40000   // Ultra 월 한도 = $400
            return snap
        }
        return base
    }

    // 이벤트 페이지네이션으로 현재 billing 기간 이벤트 증분 fetch
    func fetchEvents(sinceExclusive: Date?, periodStart: Date?) async throws -> [CursorEvent] {
        let jwt = try readAccessToken()
        let userId = try decodeUserID(jwt: jwt)
        let cookie = "\(pctEncode(userId))%3A%3A\(pctEncode(jwt))"
        let cutoff: Date? = {
            if let s = sinceExclusive, let p = periodStart { return max(s, p) }
            return sinceExclusive ?? periodStart
        }()

        var all: [CursorEvent] = []
        let pageSize = 1000
        var page = 1
        let maxPages = 20   // 안전장치

        pageLoop: while page <= maxPages {
            let body = "{\"pageSize\":\(pageSize),\"pageNumber\":\(page)}"
            let data = try await postJSON(
                "https://cursor.com/api/dashboard/get-filtered-usage-events",
                cookie: cookie, body: body,
                label: "POST filtered-usage-events page=\(page)"
            )
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let arr = obj["usageEventsDisplay"] as? [[String: Any]] else { break }
            if arr.isEmpty { break }
            var pageHadOlder = false
            for e in arr {
                guard let tsStr = e["timestamp"] as? String, let tsMs = Double(tsStr) else { continue }
                let ts = Date(timeIntervalSince1970: tsMs / 1000.0)
                if let cutoff, ts <= cutoff {
                    pageHadOlder = true
                    continue
                }
                let charged = Self.jsonDouble(e["chargedCents"])
                    ?? Self.jsonDouble((e["tokenUsage"] as? [String: Any])?["totalCents"])
                    ?? 0
                let model = e["model"] as? String
                all.append(CursorEvent(timestamp: ts, model: model, chargedCents: charged))
            }
            if pageHadOlder { break pageLoop }   // 이 페이지에 더 오래된 게 섞여있으면 이후는 불필요
            if arr.count < pageSize { break }    // 마지막 페이지
            page += 1
        }
        return all
    }

    // MARK: - HTTP helpers

    // 운영(send)·진단(perform) 두 경로가 같은 헤더를 쓰도록 request 빌드를 한 곳에 둔다.
    // 헤더가 갈라지면 진단 결과가 실제 호출과 달라지므로 builder를 단일 소스로 유지.
    private func buildGetRequest(_ urlString: String, cookie: String) -> URLRequest? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("WorkosCursorSessionToken=\(cookie)", forHTTPHeaderField: "Cookie")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        return req
    }

    private func buildPostRequest(_ urlString: String, cookie: String, body: String) -> URLRequest? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.httpBody = body.data(using: .utf8)
        req.setValue("WorkosCursorSessionToken=\(cookie)", forHTTPHeaderField: "Cookie")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
        req.setValue("https://cursor.com/dashboard", forHTTPHeaderField: "Referer")
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        return req
    }

    private func get(_ urlString: String, cookie: String, label: String) async throws -> Data {
        guard let req = buildGetRequest(urlString, cookie: cookie) else { throw CursorError.http(-1) }
        return try await send(req, label: label)
    }

    private func postJSON(_ urlString: String, cookie: String, body: String, label: String) async throws -> Data {
        guard let req = buildPostRequest(urlString, cookie: cookie, body: body) else { throw CursorError.http(-1) }
        return try await send(req, label: label)
    }

    private func send(_ req: URLRequest, label: String) async throws -> Data {
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch { throw CursorError.transport(error) }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        // body는 모델별 cost·사용 패턴 포함 — BugReport GitHub Issue로 흘러가지 않게
        // status/length만 기록. 향후 디버깅 필요 시 별도 디버그 빌드 플래그로 게이트.
        DebugLog.log(" Cursor \(label) -> status=\(status) bytes=\(data.count)")
        if status == 401 || status == 403 { throw CursorError.unauthorized }
        if !(200..<300).contains(status) { throw CursorError.http(status) }
        return data
    }

    /// JSON 숫자 필드가 Double/Int/String 중 무엇으로 와도 Double로. 비공식 엔드포인트라
    /// 응답마다 숫자 타입이 흔들려서 필요.
    private static func jsonDouble(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private func parseAggregatedCents(data: Data) -> Double {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return 0 }
        if let t = Self.jsonDouble(obj["totalCostCents"]) { return t }
        // fallback: aggregations의 totalCents 합
        guard let aggs = obj["aggregations"] as? [[String: Any]] else { return 0 }
        return aggs.reduce(0) { $0 + (Self.jsonDouble($1["totalCents"]) ?? 0) }
    }

    // MARK: - Response parsing

    private func parseUsage(data: Data, planName: String?, plan: CursorPlan) throws -> CursorSnapshot {
        struct ModelUsage: Decodable { let numRequests: Int?; let maxRequestUsage: Int? }
        // 응답은 동적 키(모델명) + "startOfMonth" 섞임 → Any 딕셔너리로 파싱
        let raw: Any
        do { raw = try JSONSerialization.jsonObject(with: data) }
        catch { throw CursorError.decoding(error) }
        guard let obj = raw as? [String: Any] else {
            throw CursorError.decoding(NSError(domain: "Cursor", code: 0))
        }

        var totalReq = 0
        var maxReq: Int? = nil
        for (k, v) in obj where k != "startOfMonth" {
            guard let model = v as? [String: Any] else { continue }
            if let n = model["numRequests"] as? Int { totalReq += n }
            if let m = model["maxRequestUsage"] as? Int {
                maxReq = max(maxReq ?? 0, m)
            }
        }

        var resetAt: Date?
        if let som = obj["startOfMonth"] as? String,
           let start = Date.parseISO8601(som) {
            // resetAt 역산(-1개월)하는 쪽들과 반드시 같은 UTC 캘린더를 공유해야 한다.
            resetAt = Calendar.utcGregorian.date(byAdding: .month, value: 1, to: start)
        }

        return CursorSnapshot(
            takenAt: Date(),
            plan: plan,
            planName: planName,
            resetAt: resetAt,
            totalRequests: totalReq,
            maxRequests: maxReq,
            totalCents: nil,
            maxCents: nil
        )
    }

    // MARK: - SQLite

    private func readAccessToken() throws -> String {
        guard let v = readString(key: "cursorAuth/accessToken"), !v.isEmpty else {
            throw CursorError.notLoggedIn
        }
        return v
    }

    private func readString(key: String) -> String? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_close(db) }
        // Cursor 앱이 실행 중이면 state.vscdb(journal_mode=delete)에 짧은 쓰기 lock이 걸린다.
        // busy_timeout 없이는 lock 순간 SQLITE_BUSY로 즉시 nil 반환 → notLoggedIn으로 오인되어
        // "Cursor 사용 중엔 사용량 집계가 통째로 누락"되는 문제가 있었다. 최대 3s 재시도하게 둔다.
        sqlite3_busy_timeout(db, 3000)

        var stmt: OpaquePointer?
        let SQLITE_TRANSIENT = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
        let sql = "SELECT value FROM ItemTable WHERE key = ?1 LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        _ = sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)

        guard sqlite3_step(stmt) == SQLITE_ROW, let cstr = sqlite3_column_text(stmt, 0) else {
            return nil
        }
        return String(cString: cstr)
    }

    // MARK: - JWT

    private func decodeUserID(jwt: String) throws -> String {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { throw CursorError.tokenRead("JWT 형식 오류") }
        guard let data = Self.base64URLDecode(String(parts[1])) else {
            throw CursorError.tokenRead("payload 디코딩 실패")
        }
        struct Payload: Decodable { let sub: String }
        do {
            return try JSONDecoder().decode(Payload.self, from: data).sub
        } catch { throw CursorError.decoding(error) }
    }

    static func base64URLDecode(_ s: String) -> Data? {
        var b64 = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let rem = b64.count % 4
        if rem > 0 { b64.append(String(repeating: "=", count: 4 - rem)) }
        return Data(base64Encoded: b64)
    }

    private func pctEncode(_ s: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    // MARK: - 로컬 진단 (--check)

    // refresh()와 같은 토큰/쿠키/parseUsage/parseAggregatedCents 경로를 그대로 타되, throw 대신
    // 단계별 status·raw body·파싱 결과를 구조체에 담아 반환한다. raw body엔 모델별 cost가
    // 들어있으므로 CLI stdout 전용 — BugReport 경로엔 안 쓴다.
    func diagnose() async -> CursorDiagnostics {
        var d = CursorDiagnostics()
        d.dbExists = FileManager.default.fileExists(atPath: dbPath)
        guard d.dbExists else { d.fatal = "Cursor 앱 미설치 (state.vscdb 없음)"; return d }
        guard let jwt = try? readAccessToken(), !jwt.isEmpty else {
            d.fatal = "Cursor 로그인 토큰 없음 (cursorAuth/accessToken)"
            return d
        }
        d.tokenFound = true
        guard let userId = try? decodeUserID(jwt: jwt) else {
            d.fatal = "JWT 디코드 실패"
            return d
        }
        d.userIdOK = true
        let planName = readString(key: "cursorAuth/stripeMembershipType")
        let plan = CursorPlan.from(planName)
        d.plan = plan
        d.planName = planName
        let cookie = "\(pctEncode(userId))%3A%3A\(pctEncode(jwt))"

        let (usageData, usageStatus) = await rawSend(get: "https://cursor.com/api/usage?user=\(pctEncode(userId))", cookie: cookie)
        d.usageStatus = usageStatus
        d.usageRawData = usageData
        if let usageData, let snap = try? parseUsage(data: usageData, planName: planName, plan: plan) {
            d.snapshot = snap
        }

        if plan == .ultra {
            let (aggData, aggStatus) = await rawSend(
                post: "https://cursor.com/api/dashboard/get-aggregated-usage-events",
                cookie: cookie, body: "{}"
            )
            d.aggStatus = aggStatus
            d.aggRawData = aggData
            if let aggData {
                let cents = parseAggregatedCents(data: aggData)
                d.snapshot?.totalCents = cents
                d.snapshot?.maxCents = 40000
            }
        }
        return d
    }

    // 진단 전용: send()와 달리 throw하지 않고 (data?, status)를 노출. builder를 공유하므로 헤더는 운영 경로와 항상 동일.
    private func rawSend(get urlString: String, cookie: String) async -> (Data?, Int) {
        guard let req = buildGetRequest(urlString, cookie: cookie) else { return (nil, -1) }
        return await perform(req)
    }

    private func rawSend(post urlString: String, cookie: String, body: String) async -> (Data?, Int) {
        guard let req = buildPostRequest(urlString, cookie: cookie, body: body) else { return (nil, -1) }
        return await perform(req)
    }

    private func perform(_ req: URLRequest) async -> (Data?, Int) {
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            return (data, (resp as? HTTPURLResponse)?.statusCode ?? -1)
        } catch {
            return (nil, -1)
        }
    }

    // 버그리포트 "사용량 이슈"용 PII-free 추출 — /api/usage 는 모델별 요청수 + startOfMonth 만 담고
    // cost/cents 는 agg 응답에만 있으므로(첨부 안 함) 통째로 떼어도 안전하다. user_id 는 URL 쿼리지
    // 응답 body 가 아니다.
    func usageDiagnostic() async -> UsageDiagnosticExtract? {
        let d = await diagnose()
        guard d.tokenFound, let data = d.usageRawData,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return UsageDiagnosticExtract(
            subtreeJson: DiagnosticExtract.subtreeJSON(from: obj, whitelist: nil),
            planType: d.planName
        )
    }
}

struct CursorDiagnostics: Sendable {
    var dbExists = false
    var tokenFound = false
    var userIdOK = false
    var plan: CursorPlan = .unknown
    var planName: String?
    var usageStatus: Int?
    var usageRawData: Data?
    var aggStatus: Int?
    var aggRawData: Data?
    var snapshot: CursorSnapshot?
    var fatal: String?
}
