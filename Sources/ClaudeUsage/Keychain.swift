import Foundation
import Security

enum Keychain {
    static let service = "ClaudeUsage"

    // 기존 Claude session — 호환을 위해 인자 없는 API 유지.
    static let claudeAccount = "sessionKey"
    // GitHub OAuth access token (device flow).
    static let githubAccount = "githubToken"

    // MARK: - Claude session (legacy API, 인자 없음)

    static func save(_ value: String) { saveItem(value, account: claudeAccount) }
    static func load() -> String? { loadItem(account: claudeAccount) }
    static func clear() { clearItem(account: claudeAccount) }

    // MARK: - GitHub token

    static func saveGitHubToken(_ value: String) { saveItem(value, account: githubAccount) }
    static func loadGitHubToken() -> String? { loadItem(account: githubAccount) }
    static func clearGitHubToken() { clearItem(account: githubAccount) }

    // MARK: - 내부 공통

    private static func saveItem(_ value: String, account: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attrs as CFDictionary, nil)
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
