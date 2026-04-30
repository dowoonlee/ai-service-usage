import Foundation

// GitHub OAuth Device Flow (RFC 8628).
// Desktop 앱은 client secret을 안전하게 보관할 수 없으므로 device flow 사용 —
// callback URL/secret 불필요. 사용자는 user_code를 브라우저에서 입력.
//
// 1) POST /login/device/code  → device_code, user_code, verification_uri
// 2) 사용자가 verification_uri를 열고 user_code 입력
// 3) interval(s)마다 POST /login/oauth/access_token 폴링 → 성공 시 access_token
actor GitHubAuth {
    static let shared = GitHubAuth()

    /// Info.plist `GitHubClientID` (빌드 시 GITHUB_CLIENT_ID 환경변수에서 주입).
    /// 비어 있거나 키가 없으면 GitHub 연동 UI는 비활성화.
    static var clientID: String? {
        guard let v = Bundle.main.object(forInfoDictionaryKey: "GitHubClientID") as? String,
              !v.isEmpty else { return nil }
        return v
    }
    static var isConfigured: Bool { clientID != nil }

    struct DeviceCodeResponse: Decodable {
        let device_code: String
        let user_code: String
        let verification_uri: String
        let expires_in: Int
        let interval: Int
    }

    struct GitHubUser: Decodable, Sendable {
        let login: String
        let id: Int
    }

    enum AuthError: LocalizedError {
        case notConfigured
        case network(String)
        case decode(String)
        case authorizationPending
        case slowDown
        case expiredToken
        case accessDenied
        case cancelled
        case unknown(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured:        return "GitHub Client ID가 설정되지 않았습니다."
            case .network(let s):       return "네트워크 오류: \(s)"
            case .decode(let s):        return "응답 디코딩 오류: \(s)"
            case .authorizationPending: return "사용자가 아직 코드를 입력하지 않았습니다."
            case .slowDown:             return "폴링 속도 제한 — 다시 시도합니다."
            case .expiredToken:         return "코드가 만료되었습니다. 다시 시도하세요."
            case .accessDenied:         return "사용자가 인증을 거부했습니다."
            case .cancelled:            return "취소됨."
            case .unknown(let s):       return s
            }
        }
    }

    /// Device flow 1단계: device/user code 발급.
    /// scope=read:user — 공개 user 정보 + login만 읽음 (PR 검색은 인증된 검색 API 사용).
    func requestDeviceCode(scope: String = "read:user") async throws -> DeviceCodeResponse {
        guard let clientID = Self.clientID else { throw AuthError.notConfigured }
        var req = URLRequest(url: URL(string: "https://github.com/login/device/code")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = "client_id=\(clientID)&scope=\(scope)".data(using: .utf8)
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            return try JSONDecoder().decode(DeviceCodeResponse.self, from: data)
        } catch let e as DecodingError {
            throw AuthError.decode("\(e)")
        } catch {
            throw AuthError.network(error.localizedDescription)
        }
    }

    /// Device flow 2단계: 토큰 폴링. 사용자가 user_code를 입력할 때까지 interval(s) 마다 재시도.
    /// expires_in을 넘기면 expiredToken throw. 호출자가 Task cancel하면 cancelled.
    func pollForToken(deviceCode: String, interval: Int, expiresIn: Int) async throws -> String {
        guard let clientID = Self.clientID else { throw AuthError.notConfigured }
        let deadline = Date().addingTimeInterval(TimeInterval(expiresIn))
        var pollInterval = interval

        while Date() < deadline {
            try await Task.sleep(nanoseconds: UInt64(pollInterval) * 1_000_000_000)
            try Task.checkCancellation()
            do {
                return try await pollOnce(clientID: clientID, deviceCode: deviceCode)
            } catch AuthError.authorizationPending {
                continue                       // 사용자가 아직 입력 안 함 — 정상 폴링
            } catch AuthError.slowDown {
                pollInterval += 5              // GitHub 요청대로 5초 늘림
                continue
            }
        }
        throw AuthError.expiredToken
    }

    private func pollOnce(clientID: String, deviceCode: String) async throws -> String {
        var req = URLRequest(url: URL(string: "https://github.com/login/oauth/access_token")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "client_id=\(clientID)&device_code=\(deviceCode)&grant_type=urn:ietf:params:oauth:grant-type:device_code"
        req.httpBody = body.data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuthError.decode("non-json response")
        }
        if let token = json["access_token"] as? String { return token }
        if let err = json["error"] as? String {
            switch err {
            case "authorization_pending": throw AuthError.authorizationPending
            case "slow_down":             throw AuthError.slowDown
            case "expired_token":         throw AuthError.expiredToken
            case "access_denied":         throw AuthError.accessDenied
            default:                      throw AuthError.unknown(err)
            }
        }
        throw AuthError.unknown("unexpected response")
    }

    /// 토큰으로 GitHub 사용자 식별 정보(login + id) 조회.
    func fetchUser(token: String) async throws -> GitHubUser {
        var req = URLRequest(url: URL(string: "https://api.github.com/user")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            return try JSONDecoder().decode(GitHubUser.self, from: data)
        } catch let e as DecodingError {
            throw AuthError.decode("\(e)")
        } catch {
            throw AuthError.network(error.localizedDescription)
        }
    }
}
