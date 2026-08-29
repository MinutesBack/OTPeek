import Foundation
import Security

/// Credentials live in the login keychain, never in the config file.
enum Keychain {
    private static let service = "OTPeek"

    /// Strips whitespace from a pasted credential.
    ///
    /// Google presents app passwords as four spaced groups ("abcd efgh ijkl
    /// mnop") and people copy them exactly as shown, but IMAP LOGIN takes the
    /// sixteen characters. Hyphens are preserved: Apple's app-specific
    /// passwords genuinely contain them.
    static func normalise(_ secret: String) -> String {
        secret.components(separatedBy: .whitespacesAndNewlines).joined()
    }

    static func set(_ secret: String, for account: String) -> Bool {
        guard let data = secret.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)

        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    /// Why a credential could not be read. "Not stored" and "blocked" need
    /// completely different responses, so they are reported separately.
    enum Failure: Error {
        case notStored
        case blocked(OSStatus)
    }

    static func read(_ account: String) -> Result<String, Failure> {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data,
           let secret = String(data: data, encoding: .utf8) {
            return .success(secret)
        }
        return .failure(status == errSecItemNotFound ? .notStored : .blocked(status))
    }

    static func get(_ account: String) -> String? {
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

    @discardableResult
    static func delete(_ account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }
}
