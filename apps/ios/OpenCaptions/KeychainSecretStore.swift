import Foundation
import OpenCaptionsKit
import Security

/// Secrets (a server's key) in the Keychain: never in preferences, never in a backup in the clear,
/// and only readable while the phone is unlocked.
struct KeychainSecretStore: SecretStore {
    private let service = "org.leogaudin.opencaptions"

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    func read(_ account: String) -> String? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func write(_ value: String, for account: String) {
        delete(account)
        var item = query(account)
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    func delete(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}
