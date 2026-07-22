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

    /// 저장 성공 여부를 반환한다 — keychain 접근 실패 시 복구가 "성공"으로 오인되지 않게(#169).
    @discardableResult
    static func saveRankingHmacKey(_ value: String) -> Bool { vault.set(rankingHmacAccount, value) }
    static func loadRankingHmacKey() -> String? { vault.get(rankingHmacAccount) }
    static func clearRankingHmacKey() { vault.remove(rankingHmacAccount) }

    /// HMAC 키가 정말 없는지(=재발급 필요) vs 지금 keychain을 못 읽는지(=재승인/재시도) 구분(#169).
    /// "인증키 유실" 배너는 `.absent`일 때만 띄우고, `.accessFailed`면 다른 안내(재승인 유도)를 한다.
    static func rankingHmacKeyLookup() -> Lookup { vault.lookup(rankingHmacAccount) }

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
    ///
    /// ⚠️ 접근 실패(ACL 재승인 거부·잠김 등)와 "항목 없음"을 반드시 구분한다(#169). 이전엔 둘 다 nil로
    /// 뭉개 vault가 살아있는데도 빈 dict로 캐시했고, 그 상태에서 set()이 호출되면 빈 dict로 vault를
    /// 덮어써 다른 값(sessionKey·githubToken 등)까지 영구 유실시켰다. 이제 접근 실패면 `loaded`를 세우지
    /// 않아 다음 접근에 재시도하고, get은 nil이 아니라 **접근 실패 신호**를 낼 수 있으며, set/remove는
    /// **덮어쓰기를 거부**한다.
    private final class Vault {
        private let queue = DispatchQueue(label: "Keychain.vault")
        private var dict: [String: String] = [:]
        private var loaded = false

        func get(_ key: String) -> String? {
            queue.sync { ensureLoaded() ? dict[key] : nil }
        }

        /// 접근 실패(잠김/ACL 거부)와 "값 없음"을 구분해 반환. 배너 분기용 — 실패면 .accessFailed.
        func lookup(_ key: String) -> Lookup {
            queue.sync {
                guard ensureLoaded() else { return .accessFailed }
                return dict[key].map(Lookup.value) ?? .absent
            }
        }

        /// dict[key] 갱신 후 전체 재저장. **로드 실패(접근 불가) 시 덮어쓰지 않는다**(false 반환).
        /// 저장 성공 시에만 캐시를 반영한다.
        @discardableResult
        func set(_ key: String, _ value: String) -> Bool {
            queue.sync {
                guard ensureLoaded() else { return false }   // 접근 실패 상태에서 vault 덮어쓰기 금지
                var d = dict
                d[key] = value
                guard Keychain.writeVaultDict(d) else { return false }
                dict = d
                return true
            }
        }

        @discardableResult
        func remove(_ key: String) -> Bool {
            queue.sync {
                guard ensureLoaded() else { return false }   // 접근 실패 상태에서 삭제(=덮어쓰기) 금지
                guard dict[key] != nil else { return true }
                var d = dict
                d.removeValue(forKey: key)
                guard Keychain.writeVaultDict(d) else { return false }
                dict = d
                return true
            }
        }

        /// queue 내부 전용 — vault 항목을 1회 로드. **접근 실패면 loaded를 세우지 않아 다음에 재시도**한다.
        /// 반환: 로드 성공(dict 유효) 여부. 실패면 캐시를 오염시키지 않는다.
        @discardableResult
        private func ensureLoaded() -> Bool {
            if loaded { return true }
            switch Keychain.readVault() {
            case .value(let json):
                dict = Keychain.parseVaultJSON(json); loaded = true; return true
            case .absent:
                // vault 항목이 정말 없음 — 레거시 이전(있으면) 후 확정. 신규 설치는 빈 dict.
                dict = Keychain.migrateLegacyItems(); loaded = true; return true
            case .accessFailed:
                return false   // 잠김/ACL 거부 — 확정하지 않고 다음 접근에 재시도
            }
        }
    }

    /// keychain 조회 3-상태 — "값 있음 / 항목 없음 / 접근 실패(잠김·ACL 거부)". #169 오판 방지.
    enum Lookup { case value(String), absent, accessFailed }

    /// vault 항목이 아직 없을 때 1회 — 옛 개별 keychain 항목을 읽어 dict로 모으고, vault로 저장한 뒤
    /// 개별 항목을 삭제한다. 이 읽기에서 (이 도입 릴리스에 한해) 존재하는 항목 수만큼 재승인 프롬프트가
    /// 뜨지만, 이후로는 vault 하나만 남아 업데이트 후 프롬프트가 1번으로 준다. 신규 설치는 이전할 값이
    /// 없어 빈 dict를 반환(프롬프트 없음). 개별 삭제 실패는 무해 — 다음 실행엔 vault가 이미 있어 재진입
    /// 하지 않고, 잔존 항목은 더 읽히지 않는 dead 데이터로 남을 뿐이다.
    private static func migrateLegacyItems() -> [String: String] {
        var d: [String: String] = [:]
        for account in legacyAccounts {
            if case .value(let v) = loadItem(account: account) { d[account] = v }
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

    /// vault 항목 원문 조회 — 접근 실패/없음/값 3-상태. 파싱은 호출부(parseVaultJSON)에서.
    private static func readVault() -> Lookup { loadItem(account: vaultAccount) }

    /// vault JSON → dict. 파싱 실패(손상)는 빈 dict(신규처럼) — 접근 실패와는 별개다.
    private static func parseVaultJSON(_ json: String) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: String] else { return [:] }
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

    /// keychain 항목 조회 — status를 구분해 3-상태로 반환한다(#169). `errSecItemNotFound`만 `.absent`,
    /// 그 외 실패(`errSecAuthFailed`·`errSecInteractionNotAllowed`·잠김 등)는 `.accessFailed`로 —
    /// "값이 없음"과 "지금 못 읽음"을 절대 뭉개지 않는다. 디코딩 실패(손상)도 접근 실패는 아니므로 .absent.
    private static func loadItem(account: String) -> Lookup {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let s = String(data: data, encoding: .utf8) else { return .absent }
            return .value(s)
        case errSecItemNotFound:
            return .absent
        default:
            return .accessFailed   // errSecAuthFailed / errSecInteractionNotAllowed / errSecNotAvailable 등
        }
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
