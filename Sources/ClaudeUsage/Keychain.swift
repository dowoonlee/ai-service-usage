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
    // 로컬 상태(coins/펫 등) 무결성 체크섬용 per-install 키. plist 외부(Keychain)에 둬야
    // `defaults write` 조작으로 올바른 체크섬을 재생성할 수 없다. 최초 1회 생성 후 고정.
    static let integrityKeyAccount = "integrityKey"
    // E2EE 쪽지 신원 개인키 (X25519 raw 32B, base64). 기기 전용 — 백업 없음(옵션 A).
    static let dmIdentityKeyAccount = "dmIdentityKey"

    // MARK: - Claude session (legacy API, 인자 없음)

    static func save(_ value: String) { saveItem(value, account: claudeAccount) }
    static func load() -> String? { loadItem(account: claudeAccount) }
    static func clear() { clearItem(account: claudeAccount) }

    // MARK: - GitHub token
    //
    // HMAC키와 동일한 사유 — ad-hoc 서명 환경에서 binary 교체 후 ACL 깨지면 매 keychain
    // 접근마다 사용자 다이얼로그 트리거. SettingsView/DailyFortuneView/ContributorBonus/복구
    // 흐름이 각자 load를 치는데 캐시 없이는 process당 4+회 접근. in-memory 캐시로 1회로 축소.
    // ContributorBonus의 자체 캐시는 그대로 두어도 무해 (첫 hit 후 둘 다 cache hit).

    private static let githubTokenCache = CachedItem(account: githubAccount)
    static func saveGitHubToken(_ value: String) { githubTokenCache.save(value) }
    static func loadGitHubToken() -> String? { githubTokenCache.load() }
    static func clearGitHubToken() { githubTokenCache.clear() }

    // MARK: - Ranking HMAC key
    //
    // ad-hoc 서명은 binary 변경마다 ACL 무효화 → 매 SecItemCopyMatching이 사용자 다이얼로그 트리거.
    // 게시판 좋아요/글쓰기처럼 호출 빈도가 잦으면 매 호출마다 prompt가 떠 UX 파괴.
    // 같은 process 내에서는 hmac key가 register/recover 시점에만 변경되므로 in-memory 캐시로
    // Keychain 접근을 process당 1회로 축소. 아래 saveRankingHmacKey가 캐시도 갱신.

    private static let rankingHmacKeyCache = CachedItem(account: rankingHmacAccount)
    static func saveRankingHmacKey(_ value: String) { rankingHmacKeyCache.save(value) }
    static func loadRankingHmacKey() -> String? { rankingHmacKeyCache.load() }
    static func clearRankingHmacKey() { rankingHmacKeyCache.clear() }

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

    // MARK: - 무결성 체크섬 키
    //
    // hmac 키와 동일하게 in-memory 캐시 — Settings의 핵심값 didSet마다 접근하므로 ad-hoc 서명
    // 환경에서 prompt 폭주를 막으려면 process당 1회로 축소해야 한다.

    // MARK: - 쪽지 신원 개인키 (E2EE)

    private static let dmIdentityKeyCache = CachedItem(account: dmIdentityKeyAccount)
    static func saveDMIdentityKey(_ value: String) { dmIdentityKeyCache.save(value) }
    static func loadDMIdentityKey() -> String? { dmIdentityKeyCache.load() }
    static func clearDMIdentityKey() { dmIdentityKeyCache.clear() }

    private static let integrityKeyCache = CachedItem(account: integrityKeyAccount)
    /// 없으면 base64(32 random bytes)를 생성·저장해 반환. 생성 실패해도 빈 문자열은 반환하지 않음.
    static func loadOrCreateIntegrityKey() -> String {
        if let existing = integrityKeyCache.load() { return existing }
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            // 난수 생성 실패(극히 드묾) — 호출 측이 체크섬을 건너뛰도록 빈 문자열.
            return ""
        }
        let key = Data(bytes).base64EncodedString()
        integrityKeyCache.save(key)
        return key
    }

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

    /// account별 in-memory 캐시 wrapper. ad-hoc 서명 환경에서 ACL 무효화 시 매 Keychain 접근이
    /// 사용자 다이얼로그를 띄우는 것을 process당 1회로 축소. 인스턴스마다 자체 직렬 큐로 보호하고,
    /// 명시적 clear는 캐시도 nil로 만들어 다음 load가 prompt 없이 nil을 반환하게 한다.
    private final class CachedItem {
        private let account: String
        private let queue: DispatchQueue
        private var cached: String?
        private var loaded = false

        init(account: String) {
            self.account = account
            self.queue = DispatchQueue(label: "Keychain.\(account).cache")
        }

        func save(_ value: String) {
            Keychain.saveItem(value, account: account)
            queue.sync { cached = value; loaded = true }
        }

        func load() -> String? {
            queue.sync {
                if loaded { return cached }
                let v = Keychain.loadItem(account: account)
                cached = v
                loaded = true
                return v
            }
        }

        func clear() {
            Keychain.clearItem(account: account)
            queue.sync { cached = nil; loaded = true }
        }
    }
}
