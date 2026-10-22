import Foundation
import Security

/// Stores the API key in the macOS login Keychain rather than in a plain file.
enum Keychain {
    private static let base: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "ClaudeChat.anthropic-api-key",
        kSecAttrAccount as String: "default",
    ]

    static func load() -> String? {
        var q = base
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        delete()
        var q = base
        q[kSecValueData as String] = Data(key.utf8)
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        SecItemDelete(base as CFDictionary)
    }
}
