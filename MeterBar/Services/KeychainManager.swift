import Foundation
import Security

/// Minimal generic-password keychain interface.

protocol KeychainBackend {
    func save(key: String, value: String) -> Bool
    func get(key: String) -> String?
    func delete(key: String) -> Bool
    func hasKey(key: String) -> Bool
}

extension KeychainBackend {
    func hasKey(key: String) -> Bool {
        return get(key: key) != nil
    }
}

final class KeychainManager: KeychainBackend {
    static let shared = KeychainManager()

    private let service: String

    /// Production singleton uses the app's bundle-id-shaped service name.
    /// Tests pass a unique per-class identifier so concurrent test runs don't
    /// collide and `tearDown` can clean up its own items.
    init(service: String = "com.jmdeejay.meterbar") {
        self.service = service
    }

    func save(key: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data
        ]

        // Delete existing item
        SecItemDelete(query as CFDictionary)

        // Add new item
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    func get(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }

        return value
    }

    func delete(key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
