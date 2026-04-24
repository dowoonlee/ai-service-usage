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
        case .decoding(let e): return "응답 해석 오류: \(e.localizedDescription)"
        }
    }
}

actor CursorAPI {
    static let shared = CursorAPI()

    private let dbPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
    }()
    private let ua = "ClaudeUsage/1.0"

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
        let usageData = try await get("https://cursor.com/api/usage?user=\(userId)", cookie: cookie, label: "GET /api/usage")
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
                var charged: Double = 0
                if let c = e["chargedCents"] as? Double { charged = c }
                else if let c = e["chargedCents"] as? Int { charged = Double(c) }
                else if let tu = e["tokenUsage"] as? [String: Any], let c = tu["totalCents"] as? Double { charged = c }
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

    private func get(_ urlString: String, cookie: String, label: String) async throws -> Data {
        guard let url = URL(string: urlString) else { throw CursorError.http(-1) }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("WorkosCursorSessionToken=\(cookie)", forHTTPHeaderField: "Cookie")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        return try await send(req, label: label)
    }

    private func postJSON(_ urlString: String, cookie: String, body: String, label: String) async throws -> Data {
        guard let url = URL(string: urlString) else { throw CursorError.http(-1) }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.httpBody = body.data(using: .utf8)
        req.setValue("WorkosCursorSessionToken=\(cookie)", forHTTPHeaderField: "Cookie")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
        req.setValue("https://cursor.com/dashboard", forHTTPHeaderField: "Referer")
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        return try await send(req, label: label)
    }

    private func send(_ req: URLRequest, label: String) async throws -> Data {
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch { throw CursorError.transport(error) }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        let preview = String(data: data.prefix(1200), encoding: .utf8) ?? "<binary>"
        DebugLog.log(" Cursor \(label) -> status=\(status) body=\(preview)")
        if status == 401 || status == 403 { throw CursorError.unauthorized }
        if !(200..<300).contains(status) { throw CursorError.http(status) }
        return data
    }

    private func parseAggregatedCents(data: Data) -> Double {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return 0 }
        if let t = obj["totalCostCents"] as? Double { return t }
        if let t = obj["totalCostCents"] as? Int { return Double(t) }
        if let s = obj["totalCostCents"] as? String, let t = Double(s) { return t }
        // fallback: aggregations의 totalCents 합
        guard let aggs = obj["aggregations"] as? [[String: Any]] else { return 0 }
        var total: Double = 0
        for a in aggs {
            if let c = a["totalCents"] as? Double { total += c }
            else if let c = a["totalCents"] as? Int { total += Double(c) }
            else if let s = a["totalCents"] as? String, let c = Double(s) { total += c }
        }
        return total
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
        if let som = obj["startOfMonth"] as? String {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let iso2 = ISO8601DateFormatter()
            iso2.formatOptions = [.withInternetDateTime]
            if let start = iso.date(from: som) ?? iso2.date(from: som) {
                var cal = Calendar(identifier: .gregorian)
                cal.timeZone = TimeZone(identifier: "UTC")!
                resetAt = cal.date(byAdding: .month, value: 1, to: start)
            }
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
}
