import Foundation
import Security

/// Small wrapper over the login Keychain for Longarm's secrets (the speech-to-text API key).
enum Keychain {
    private static let service = "dev.longarm.mac"

    static func read(_ account: String) -> String? {
        var result: AnyObject?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ value: String, account: String) {
        delete(account)
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
        ]
        SecItemAdd(item as CFDictionary, nil)
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// A service's API key: which Keychain item holds it and how the key dialog describes it.
struct ApiKeyKind {
    let name: String          // "Deepgram", …
    let account: String
    let usedFor: String       // "Used for live transcription"
    let keyPage: String       // where to create one
    let looksValid: (String) -> Bool
}
