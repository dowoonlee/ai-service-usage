import Foundation
import Security

enum Keychain {
    static let service = "ClaudeUsage"

    // 기존 Claude session — 호환을 위해 인자 없는 API 유지.
    static let claudeAccount = "sessionKey"
    // GitHub OAuth access token (device flow).
    static let githubAccount = "githubToken"
    // 랭킹 서버가 register 시 발급한 per-install HMAC 키 (base64). payload 서명에 사용.
    static let rankingHmacAccount = "rankingHmacKey"
    // 랭킹 서버가 register 시 발급한 복구 코드 (XXXX-XXXX-XXXX). 분실 시 GitHub 연동과 함께
    // 계정 복구 수단으로 사용. v0.8.10부터 UserDefaults → Keychain으로 저장소 이동.
    static let rankingRecoveryCodeAccount = "rankingRecoveryCode"

    // MARK: - Claude session (legacy API, 인자 없음)

    static func save(_ value: String) { saveItem(value, account: claudeAccount) }
    static func load() -> String? { loadItem(account: claudeAccount) }
    static func clear() { clearItem(account: claudeAccount) }

    // MARK: - GitHub token

    static func saveGitHubToken(_ value: String) { saveItem(value, account: githubAccount) }
    static func loadGitHubToken() -> String? { loadItem(account: githubAccount) }
    static func clearGitHubToken() { clearItem(account: githubAccount) }

    // MARK: - Ranking HMAC key
    //
    // ad-hoc 서명은 binary 변경마다 ACL 무효화 → 매 SecItemCopyMatching이 사용자 다이얼로그 트리거.
    // 게시판 좋아요/글쓰기처럼 호출 빈도가 잦으면 매 호출마다 prompt가 떠 UX 파괴.
    // 같은 process 내에서는 hmac key가 register/recover 시점에만 변경되므로 in-memory 캐시로
    // Keychain 접근을 process당 1회로 축소. 아래 saveRankingHmacKey가 캐시도 갱신.

    private static let _hmacKeyQueue = DispatchQueue(label: "Keychain.rankingHmacKey.cache")
    private static var _cachedRankingHmacKey: String?
    private static var _hmacKeyLoaded: Bool = false

    static func saveRankingHmacKey(_ value: String) {
        saveItem(value, account: rankingHmacAccount)
        _hmacKeyQueue.sync {
            _cachedRankingHmacKey = value
            _hmacKeyLoaded = true
        }
    }

    static func loadRankingHmacKey() -> String? {
        _hmacKeyQueue.sync {
            if _hmacKeyLoaded { return _cachedRankingHmacKey }
            let v = loadItem(account: rankingHmacAccount)
            _cachedRankingHmacKey = v
            _hmacKeyLoaded = true
            return v
        }
    }

    static func clearRankingHmacKey() {
        clearItem(account: rankingHmacAccount)
        _hmacKeyQueue.sync {
            _cachedRankingHmacKey = nil
            _hmacKeyLoaded = true   // 명시적 clear는 캐시도 nil로 — 다음 load가 prompt 안 뜨고 nil
        }
    }

    // MARK: - Ranking recovery code
    //
    // Settings의 @Published var rankingRecoveryCode가 in-memory 캐시 역할을 하므로 별도 캐시
    // 불필요 — init에서 1회 load 후 didSet에서만 save.

    @discardableResult
    static func saveRecoveryCode(_ value: String) -> Bool {
        saveItem(value, account: rankingRecoveryCodeAccount)
    }
    static func loadRecoveryCode() -> String? { loadItem(account: rankingRecoveryCodeAccount) }
    static func clearRecoveryCode() { clearItem(account: rankingRecoveryCodeAccount) }

    // MARK: - 내부 공통

    /// SecItemAdd 우선, 이미 존재하면 SecItemUpdate. 기존 Delete+Add 방식은 한 번의 save에
    /// keychain access를 2번 트리거해 ad-hoc 서명 + ACL 무효화 상황에서 사용자에게 다이얼로그가
    /// 두 번 뜨던 문제 — Add/Update 한 번으로 1회로 축소.
    @discardableResult
    private static func saveItem(_ value: String, account: String) -> Bool {
        let data = Data(value.utf8)
        let matchQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        var addAttrs = matchQuery
        addAttrs[kSecValueData as String] = data
        addAttrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(addAttrs as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateAttrs: [String: Any] = [kSecValueData as String: data]
            return SecItemUpdate(matchQuery as CFDictionary, updateAttrs as CFDictionary) == errSecSuccess
        }
        return status == errSecSuccess
    }

    private static func loadItem(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    private static func clearItem(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
