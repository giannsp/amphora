import Foundation
import Security

/// Stores the Jamf API client secret in the login keychain, never in preferences or logs.
public enum Keychain {
    static let service = "consulting.techne.amphora.jamf"
    /// Where releases before the rename to Amphora kept the secret.
    static let legacyService = "consulting.techne.ipswmirror.jamf"

    /// Reads the secret. A secret saved under the old name is moved to the new one on first read.
    public static func secret(for account: String) -> String? {
        if let secret = read(service: service, account: account) { return secret }
        guard let legacy = read(service: legacyService, account: account) else { return nil }
        if (try? setSecret(legacy, for: account)) != nil {
            delete(service: legacyService, account: account)
        }
        return legacy
    }

    public static func setSecret(_ secret: String, for account: String) throws {
        delete(service: service, account: account)
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(secret.utf8),
            kSecAttrLabel as String: "Amphora – Jamf Pro API client",
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    public static func removeSecret(for account: String) {
        delete(service: service, account: account)
        delete(service: legacyService, account: account)
    }

    private static func read(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func delete(service: String, account: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }
}
