import Foundation
import Security

/// Tokens live in the Keychain, in the app group's access group so the share extensions can read them.
/// Unsigned debug builds have no keychain entitlement; they fall back to UserDefaults so they still run.
final class TokenStore {
    private let accessGroup: String?
    private let fallback: UserDefaults
    private let service = "Droprr"
    private(set) var usingKeychain = true
    /// Set when a read failed for a reason other than "not found" (e.g. the Keychain is locked), so callers
    /// don't mistake it for a missing item and replace or delete what's stored.
    private(set) var hadReadError = false

    init(accessGroup: String?, fallback: UserDefaults) {
        self.accessGroup = accessGroup
        self.fallback = fallback
    }

    /// Plain UserDefaults storage when the Keychain entitlement is missing (unsigned builds). A release build
    /// is signed with keychain-access-groups, so it doesn't get here; items an older build left in UserDefaults
    /// are moved into the Keychain the first time they're read.
    private static let fallbackAllowed = true

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
        if status == errSecMissingEntitlement && Self.fallbackAllowed {
            usingKeychain = false
            return get(key)
        }
        if status != errSecSuccess && status != errSecItemNotFound { hadReadError = true }
        if status == errSecItemNotFound, let legacy = fallback.string(forKey: "keychain." + key) {
            // Left in UserDefaults by an earlier build without the Keychain entitlement: move it in.
            set(legacy, for: key)
            if usingKeychain { fallback.removeObject(forKey: "keychain." + key) }
            return legacy
        }
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func set(_ value: String?, for key: String) {
        guard let value, !value.isEmpty else { return remove(key) }
        guard usingKeychain else { return fallback.set(value, forKey: "keychain." + key) }
        let data = Data(value.utf8)
        var status = SecItemUpdate(query(key) as CFDictionary, [kSecValueData as String: data,
                                                               kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(key)
            add[kSecValueData as String] = data
            // Never in backups or migrations to another device: a copied identity could impersonate this one.
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status == errSecMissingEntitlement && Self.fallbackAllowed {
            usingKeychain = false
            set(value, for: key)
        }
    }

    func remove(_ key: String) {
        guard usingKeychain else { return fallback.removeObject(forKey: "keychain." + key) }
        let status = SecItemDelete(query(key) as CFDictionary)
        if status == errSecMissingEntitlement && Self.fallbackAllowed {
            usingKeychain = false
            remove(key)
        }
    }
}
