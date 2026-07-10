import Foundation
import Security

/// 앱의 모든 민감 값(세션키·토큰·HMAC키·복구코드·무결성키·쪽지키)을 **단일 keychain 항목**
/// (`vaultAccount`)에 JSON `{논리키: 값}` 하나로 담는다.
///
/// 왜 하나로 합쳤나 — ad-hoc 서명 환경에선 앱 업데이트마다 바이너리 cdhash가 바뀌어 각 항목의
/// ACL(접근 허용 앱 목록)이 무효화되고, 항목에 처음 접근할 때 macOS 재승인 다이얼로그가 뜬다.
/// 이 프롬프트는 keychain "항목(item) 단위"라, 값이 6개의 별도 항목이면 업데이트 후 6번 떴다.
/// 값들을 vault 항목 하나에 모으면 항목이 1개뿐이라 **업데이트 후 프롬프트가 1번**으로 준다.
/// (프롬프트를 0번으로 없애는 건 Developer ID 서명뿐 — ad-hoc의 구조적 한계.)
///
/// in-memory 캐시(`Vault`)가 process당 keychain 접근을 1회로 축소하고, 옛 버전에서 만든 개별
/// 항목은 vault 첫 접근 시 자동 이전(`migrateLegacyItems`)한다.
enum Keychain {
    static let service = "ClaudeUsage"

    // 논리 키 이름 — v0.15.x까지는 각각 별도 keychain account였고, 지금은 단일 vault JSON의 key다.
    // 문자열 값은 옛 account 이름 그대로 유지한다 (레거시 마이그레이션이 이 이름으로 기존 항목을 읽음).
    static let claudeAccount = "sessionKey"            // claude.ai 웹 세션 쿠키
    static let githubAccount = "githubToken"           // GitHub OAuth access token (device flow)
    static let rankingHmacAccount = "rankingHmacKey"   // 랭킹 서버 register 시 발급한 per-install HMAC 키
    static let rankingRecoveryCodeAccount = "rankingRecoveryCode"  // 계정 복구 코드
    static let integrityKeyAccount = "integrityKey"    // 로컬 상태 무결성 체크섬 키 (plist 외부 필수)
    static let dmIdentityKeyAccount = "dmIdentityKey"  // E2EE 쪽지 신원 개인키 (X25519 raw 32B, base64)

    /// 위 6개 값을 담는 통합 저장소 account. 항목이 이거 하나뿐이라 ACL 재승인 프롬프트도 1번.
    private static let vaultAccount = "vault"

    /// 마이그레이션 대상 옛 개별 account 목록 (vault 도입 전 저장 위치).
    private static let legacyAccounts = [
        claudeAccount, githubAccount, rankingHmacAccount,
        rankingRecoveryCodeAccount, integrityKeyAccount, dmIdentityKeyAccount,
    ]

    private static let vault = Vault()

    // MARK: - Claude session (legacy API, 인자 없음 — 호환 유지)

    static func save(_ value: String) { vault.set(claudeAccount, value) }
    static func load() -> String? { vault.get(claudeAccount) }
    static func clear() { vault.remove(claudeAccount) }

    // MARK: - GitHub token

    static func saveGitHubToken(_ value: String) { vault.set(githubAccount, value) }
    static func loadGitHubToken() -> String? { vault.get(githubAccount) }
    static func clearGitHubToken() { vault.remove(githubAccount) }

    // MARK: - Ranking HMAC key

    static func saveRankingHmacKey(_ value: String) { vault.set(rankingHmacAccount, value) }
    static func loadRankingHmacKey() -> String? { vault.get(rankingHmacAccount) }
    static func clearRankingHmacKey() { vault.remove(rankingHmacAccount) }

    // MARK: - Ranking recovery code

    @discardableResult
    static func saveRecoveryCode(_ value: String) -> Bool { vault.set(rankingRecoveryCodeAccount, value) }
    static func loadRecoveryCode() -> String? { vault.get(rankingRecoveryCodeAccount) }
    static func clearRecoveryCode() { vault.remove(rankingRecoveryCodeAccount) }

    // MARK: - 쪽지 신원 개인키 (E2EE)

    static func saveDMIdentityKey(_ value: String) { vault.set(dmIdentityKeyAccount, value) }
    static func loadDMIdentityKey() -> String? { vault.get(dmIdentityKeyAccount) }
    static func clearDMIdentityKey() { vault.remove(dmIdentityKeyAccount) }

    // MARK: - 무결성 체크섬 키

    /// 없으면 base64(32 random bytes)를 생성·저장해 반환. 생성 실패해도 빈 문자열은 반환하지 않음.
    static func loadOrCreateIntegrityKey() -> String {
        if let existing = vault.get(integrityKeyAccount) { return existing }
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            // 난수 생성 실패(극히 드묾) — 호출 측이 체크섬을 건너뛰도록 빈 문자열.
            return ""
        }
        let key = Data(bytes).base64EncodedString()
        vault.set(integrityKeyAccount, key)
        return key
    }

    // MARK: - Vault (단일 항목 캐시 + read-modify-write)

    /// vault dict를 통째로 in-memory 캐시하고, 모든 R/W를 직렬 큐에서 처리한다. ad-hoc 서명 환경에서
    /// keychain 접근을 process당 1회로 축소하고, 한 값만 바꿔도 dict 전체를 재저장(SecItemUpdate)한다.
    private final class Vault {
        private let queue = DispatchQueue(label: "Keychain.vault")
        private var dict: [String: String] = [:]
        private var loaded = false

        func get(_ key: String) -> String? {
            queue.sync { ensureLoaded(); return dict[key] }
        }

        /// dict[key] 갱신 후 전체 재저장. 저장 성공 시에만 캐시를 반영한다.
        @discardableResult
        func set(_ key: String, _ value: String) -> Bool {
            queue.sync {
                ensureLoaded()
                var d = dict
                d[key] = value
                guard Keychain.writeVaultDict(d) else { return false }
                dict = d
                return true
            }
        }

        func remove(_ key: String) {
            queue.sync {
                ensureLoaded()
                guard dict[key] != nil else { return }
                var d = dict
                d.removeValue(forKey: key)
                if Keychain.writeVaultDict(d) { dict = d }
            }
        }

        /// queue 내부 전용 — vault 항목을 1회 로드. 없으면 레거시 개별 항목을 이전해 온다.
        private func ensureLoaded() {
            if loaded { return }
            loaded = true
            dict = Keychain.readVaultDict() ?? Keychain.migrateLegacyItems()
        }
    }

    /// vault 항목이 아직 없을 때 1회 — 옛 개별 keychain 항목을 읽어 dict로 모으고, vault로 저장한 뒤
    /// 개별 항목을 삭제한다. 이 읽기에서 (이 도입 릴리스에 한해) 존재하는 항목 수만큼 재승인 프롬프트가
    /// 뜨지만, 이후로는 vault 하나만 남아 업데이트 후 프롬프트가 1번으로 준다. 신규 설치는 이전할 값이
    /// 없어 빈 dict를 반환(프롬프트 없음). 개별 삭제 실패는 무해 — 다음 실행엔 vault가 이미 있어 재진입
    /// 하지 않고, 잔존 항목은 더 읽히지 않는 dead 데이터로 남을 뿐이다.
    private static func migrateLegacyItems() -> [String: String] {
        var d: [String: String] = [:]
        for account in legacyAccounts {
            if let v = loadItem(account: account) { d[account] = v }
        }
        guard !d.isEmpty else { return [:] }   // 신규 설치 — 이전할 것 없음
        if writeVaultDict(d) {
            // ⚠️ 읽어서 vault로 옮긴 항목(`d.keys`)만 삭제한다. 과거 버그: `legacyAccounts` 전체를
            // 지우는 바람에, ad-hoc ACL 재승인 프롬프트를 거부/취소해 loadItem이 실패한 항목의
            // 원본까지 삭제돼 영구 유실됐다(예: integrityKey 유실 → 체크섬 키 재생성 → 무결성 오탐).
            // 못 읽은 원본은 남겨 유실을 막는다(vault가 이미 생겨 재진입은 없으므로 dead 데이터로
            // 남을 뿐, 삭제 실패와 동일하게 무해).
            for account in d.keys { clearItem(account: account) }
        }
        return d
    }

    // MARK: - 내부 primitives (vault 항목 자체 R/W + 레거시 읽기/삭제)

    private static func readVaultDict() -> [String: String]? {
        guard let json = loadItem(account: vaultAccount),
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: String] else { return nil }
        return dict
    }

    @discardableResult
    private static func writeVaultDict(_ d: [String: String]) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return false }
        return saveItem(json, account: vaultAccount)
    }

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
