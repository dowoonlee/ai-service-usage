import Foundation
import CryptoKit

/// 글로벌 랭킹 보드용 Supabase 클라이언트.
///
/// 인증 모델은 `UsageAPI`/`CursorAPI`와 다름 — Supabase anon key + per-install HMAC 키
/// 조합. 옵트인 시점에 서버 register → recovery code + HMAC 키 발급, 이후 모든 submit은
/// payload를 HMAC-SHA256으로 서명. 어뷰징의 1차 방어선이지만 클라이언트 patch에는 무력 —
/// 서버측 시간 비례 하드캡(elapsed × max_natural_rate × margin)이 실제 방어선.
///
/// Info.plist 키:
///   - `SupabaseURL`        — 프로젝트 URL (e.g. https://xxx.supabase.co)
///   - `SupabaseAnonKey`    — anon 공개 키 (브라우저 노출 OK, Row Level Security가 권한 통제)
///   - `PrivacyPolicyURL`   — 옵트인 동의 화면에서 노출할 처리방침 URL
///
/// 위 3개가 모두 비어 있으면 `isConfigured == false` → UI는 "이 빌드는 랭킹 미지원" 안내만.
actor RankingAPI {
    static let shared = RankingAPI()

    static var baseURL: URL? {
        guard var s = Bundle.main.object(forInfoDictionaryKey: "SupabaseURL") as? String,
              !s.isEmpty else { return nil }
        // Data API URL을 통째로 박은 경우(끝에 `/rest/v1/` 붙음) 자동 정규화 —
        // sanity_check_ranking.sh와 동일 로직. 사용자 실수 방어.
        if s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix("/rest/v1") { s.removeLast("/rest/v1".count) }
        if s.hasSuffix("/") { s.removeLast() }
        return URL(string: s)
    }
    static var anonKey: String? {
        let s = Bundle.main.object(forInfoDictionaryKey: "SupabaseAnonKey") as? String
        return (s?.isEmpty == false) ? s : nil
    }
    static var privacyPolicyURL: URL? {
        guard let s = Bundle.main.object(forInfoDictionaryKey: "PrivacyPolicyURL") as? String,
              !s.isEmpty else { return nil }
        return URL(string: s)
    }
    static var isConfigured: Bool { baseURL != nil && anonKey != nil }

    // MARK: - Models

    struct RegisterRequest: Encodable {
        let deviceId: String
        let nickname: String
        let githubLogin: String?
        let githubUserId: Int?
        /// 옵트인 시점의 `coinsTotalEarned`. 서버는 그대로 total_coins로 저장 (누적값 인정).
        /// 1M cap (서버측).
        let initialCoins: Int?
        let profileJson: ProfileState?
    }
    struct RegisterResponse: Decodable {
        let hmacKey: String
        let recoveryCode: String
        let nickname: String
    }

    struct SubmitPayload: Encodable {
        let deviceId: String
        let delta: Int
        let prevTotal: Int
        let ts: Int64
    }
    struct SubmitRequest: Encodable {
        let payload: SubmitPayload
        let signature: String
        /// payload 외부 — HMAC 서명 대상 아님. 변조 위험 작아 display data로 수용.
        let profileJson: ProfileState?
    }
    struct SubmitResponse: Decodable {
        let accepted: Bool
        let totalCoins: Int
        let rejectReason: String?
    }

    struct LeaderboardEntry: Decodable, Identifiable, Sendable {
        let rank: Int
        let nickname: String
        let totalCoins: Int
        let githubLogin: String?
        /// 트레이너 카드 + stats — 보드 행/팝오버 렌더링 입력. 미옵트인/구버전 사용자는 nil.
        let profileJson: ProfileState?
        var id: Int { rank }
    }
    struct LeaderboardResponse: Decodable {
        let entries: [LeaderboardEntry]
        let myRank: Int?
        let myTotalCoins: Int?
        let total: Int
        /// "monthly" — 현재 운영 중인 보드 종류. 추후 weekly/all-time 추가 시 확장.
        let period: String?
        /// 다음 리셋 시각 (UTC ISO 8601). 보드 헤더의 "리셋까지" 카운트다운 표시용.
        let periodResetAt: Date?
    }

    struct RecoverByCodeRequest: Encodable {
        let recoveryCode: String
        let newDeviceId: String
    }
    struct RecoverByGitHubRequest: Encodable {
        let githubToken: String
        let newDeviceId: String
    }
    struct RecoverResponse: Decodable {
        /// 서버측 권위 있는 device_id. 클라이언트가 보낸 newDeviceId는 무시되고 기존 값이
        /// 반환됨 → 클라이언트는 이걸 받아 로컬 `rankingDeviceID`에 저장해야 함. 서버측
        /// submissions FK 변경 없이 hmac_key만 rotate하는 설계.
        let deviceId: String
        let hmacKey: String
        let nickname: String
        let totalCoins: Int
    }

    // MARK: - Errors

    enum RankingError: LocalizedError {
        case notConfigured
        case notRegistered
        case nicknameTaken
        case invalidRecoveryCode
        case banned
        case privacyNotAccepted
        case http(Int, String?)
        case decoding(String)
        case network(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured:       return "랭킹 기능이 이 빌드에 포함되지 않았습니다."
            case .notRegistered:       return "랭킹 등록이 필요합니다."
            case .nicknameTaken:       return "이미 사용 중인 닉네임입니다."
            case .invalidRecoveryCode: return "복구 코드가 올바르지 않습니다."
            case .banned:              return "이 계정은 운영 정책 위반으로 차단되었습니다."
            case .privacyNotAccepted:  return "처리방침 동의가 필요합니다."
            case .http(let code, let msg):
                return "서버 오류 \(code)\(msg.map { ": \($0)" } ?? "")"
            case .decoding(let s):     return "응답 디코딩 오류: \(s)"
            case .network(let s):      return "네트워크 오류: \(s)"
            }
        }
    }

    // MARK: - Public API

    /// 첫 옵트인 시 호출. 서버가 hmacKey + recoveryCode 발급. 성공 시 Keychain/Settings 갱신.
    /// 닉네임 중복 시 `.nicknameTaken` throw — 호출 측이 다른 닉네임으로 재시도.
    func register(deviceId: String, nickname: String,
                  githubLogin: String?, githubUserId: Int?,
                  initialCoins: Int?, profileJson: ProfileState?) async throws -> RegisterResponse {
        let req = RegisterRequest(deviceId: deviceId, nickname: nickname,
                                  githubLogin: githubLogin, githubUserId: githubUserId,
                                  initialCoins: initialCoins, profileJson: profileJson)
        return try await post(path: "register", body: req, signed: false)
    }

    /// 폴링 cycle 직후 호출 (fire-and-forget). delta = 현재 coinsTotalEarned - lastSubmittedTotal.
    /// delta <= 0이면 호출 측에서 skip — 여기까지 와도 서버가 0을 거부할 수도 있어서.
    /// profileJson은 매 호출마다 최신 ProfileState 전달 (display 갱신).
    func submitDelta(deviceId: String, delta: Int, prevTotal: Int,
                     hmacKeyBase64: String, profileJson: ProfileState?) async throws -> SubmitResponse {
        let payload = SubmitPayload(deviceId: deviceId, delta: delta, prevTotal: prevTotal,
                                    ts: Int64(Date().timeIntervalSince1970))
        let sig = try Self.sign(payload: payload, keyBase64: hmacKeyBase64)
        let req = SubmitRequest(payload: payload, signature: sig, profileJson: profileJson)
        return try await post(path: "submit", body: req, signed: true)
    }

    /// Top N + 내 순위. 페이지네이션 없이 한 번에 받음 (50명 규모라 부담 없음).
    func fetchLeaderboard(deviceId: String?) async throws -> LeaderboardResponse {
        let q = deviceId.map { [URLQueryItem(name: "deviceId", value: $0)] }
        return try await get(path: "leaderboard", queryItems: q)
    }

    /// 새 device에서 복구 코드 입력 → 서버가 새 device_id로 hmacKey 재발급. 기존 hmacKey 무효화.
    func recoverWithRecoveryCode(_ code: String, newDeviceId: String) async throws -> RecoverResponse {
        let req = RecoverByCodeRequest(recoveryCode: code, newDeviceId: newDeviceId)
        do {
            return try await post(path: "recover-by-code", body: req, signed: false)
        } catch RankingError.http(404, _) {
            throw RankingError.invalidRecoveryCode
        }
    }

    /// 새 device에서 GitHub OAuth 토큰 → 서버가 GitHub API로 user 확인 → 매칭 user에 재발급.
    func recoverWithGitHub(token: String, newDeviceId: String) async throws -> RecoverResponse {
        let req = RecoverByGitHubRequest(githubToken: token, newDeviceId: newDeviceId)
        do {
            return try await post(path: "recover-by-github", body: req, signed: false)
        } catch RankingError.http(404, _) {
            throw RankingError.invalidRecoveryCode
        }
    }

    /// 계정 영구 삭제. 서버측 row + submissions 로그 모두 제거.
    func deleteAccount(deviceId: String, hmacKeyBase64: String) async throws {
        let payload = SubmitPayload(deviceId: deviceId, delta: 0, prevTotal: 0,
                                    ts: Int64(Date().timeIntervalSince1970))
        let sig = try Self.sign(payload: payload, keyBase64: hmacKeyBase64)
        let req = SubmitRequest(payload: payload, signature: sig, profileJson: nil)
        let _: EmptyResponse = try await post(path: "delete", body: req, signed: true)
    }

    private struct EmptyResponse: Decodable {}

    // MARK: - HMAC

    /// payload를 sortedKeys JSON으로 정렬 후 HMAC-SHA256. 서버측도 동일 규칙으로 검증.
    /// hex 소문자 출력.
    static func sign(payload: SubmitPayload, keyBase64: String) throws -> String {
        guard let keyData = Data(base64Encoded: keyBase64) else {
            throw RankingError.decoding("invalid HMAC key base64")
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let body = try enc.encode(payload)
        let key = SymmetricKey(data: keyData)
        let mac = HMAC<SHA256>.authenticationCode(for: body, using: key)
        return Data(mac).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - HTTP helpers

    private func post<Req: Encodable, Resp: Decodable>(
        path: String, body: Req, signed: Bool
    ) async throws -> Resp {
        guard let base = Self.baseURL, let anon = Self.anonKey else {
            throw RankingError.notConfigured
        }
        let url = base.appendingPathComponent("functions/v1/\(path)")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(anon)", forHTTPHeaderField: "Authorization")
        req.setValue(anon, forHTTPHeaderField: "apikey")

        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            req.httpBody = try enc.encode(body)
        } catch {
            throw RankingError.decoding("encode: \(error.localizedDescription)")
        }
        _ = signed // 서명은 body 내부 signature 필드로 전달, header는 anon key만.

        return try await execute(req)
    }

    private func get<Resp: Decodable>(path: String, queryItems: [URLQueryItem]? = nil) async throws -> Resp {
        guard let base = Self.baseURL, let anon = Self.anonKey else {
            throw RankingError.notConfigured
        }
        // appendingPathComponent로 path만 붙이고, query는 URLComponents로 따로 구성.
        // 단순 문자열 결합 시 `?`가 percent-encode되어 path의 일부가 되는 버그를 회피.
        let pathURL = base.appendingPathComponent("functions/v1/\(path)")
        var components = URLComponents(url: pathURL, resolvingAgainstBaseURL: false)
        components?.queryItems = queryItems
        guard let url = components?.url else { throw RankingError.notConfigured }
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(anon)", forHTTPHeaderField: "Authorization")
        req.setValue(anon, forHTTPHeaderField: "apikey")
        return try await execute(req)
    }

    private func execute<Resp: Decodable>(_ req: URLRequest) async throws -> Resp {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw RankingError.network(error.localizedDescription)
        }
        let http = response as? HTTPURLResponse
        let code = http?.statusCode ?? 0

        if code == 409 { throw RankingError.nicknameTaken }
        if code == 403 { throw RankingError.banned }
        if code == 412 { throw RankingError.privacyNotAccepted }
        // 404는 endpoint별로 의미가 다름 — recover-by-code/github의 "not found"는 호출 측이
        // body 메시지(`recovery_code_not_found` / `no_account_linked_to_github`)로 분기 매핑.
        // 여기선 generic .http(404, body)로만 감싸 사용자에게 정확한 메시지 노출.
        guard (200..<300).contains(code) else {
            let body = String(data: data, encoding: .utf8)
            throw RankingError.http(code, body)
        }
        if Resp.self == EmptyResponse.self {
            return EmptyResponse() as! Resp
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(Resp.self, from: data)
        } catch {
            throw RankingError.decoding(error.localizedDescription)
        }
    }
}
