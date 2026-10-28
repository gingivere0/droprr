import Foundation
import Security

/// Tokens live in the Keychain, in the app group's access group so the share extensions can read them.
/// Unsigned debug builds have no keychain entitlement; they fall back to UserDefaults so they still run.
final class TokenStore {
    private let accessGroup: String?
    private let fallback: UserDefaults
    private let service = "Droprr"
    private(set) var usingKeychain = true

    init(accessGroup: String?, fallback: UserDefaults) {
        self.accessGroup = accessGroup
        self.fallback = fallback
    }

    private func query(_ key: String) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        if let accessGroup { q[kSecAttrAccessGroup as String] = accessGroup }
        #if os(macOS)
        q[kSecUseDataProtectionKeychain as String] = true
        #endif
        return q
    }

    func get(_ key: String) -> String? {
        guard usingKeychain else { return fallback.string(forKey: "keychain." + key) }
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecMissingEntitlement {
            usingKeychain = false
            return get(key)
        }
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func set(_ value: String?, for key: String) {
        guard let value, !value.isEmpty else { return remove(key) }
        guard usingKeychain else { return fallback.set(value, forKey: "keychain." + key) }
        let data = Data(value.utf8)
        var status = SecItemUpdate(query(key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(key)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status == errSecMissingEntitlement {
            usingKeychain = false
            set(value, for: key)
        }
    }

    func remove(_ key: String) {
        guard usingKeychain else { return fallback.removeObject(forKey: "keychain." + key) }
        let status = SecItemDelete(query(key) as CFDictionary)
        if status == errSecMissingEntitlement {
            usingKeychain = false
            remove(key)
        }
    }
}
