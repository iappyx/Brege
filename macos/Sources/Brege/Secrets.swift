import BregeCore
import Foundation
import Security

/// Identity seed and database key, kept in the login Keychain.
struct Secrets {
    let identitySeed: Data
    let databaseKey: Data

    private static let service = "app.brege.mac"

    static func loadOrCreate() throws -> Secrets {
        Secrets(
            identitySeed: try loadOrCreate(account: "identity-seed") { try generateIdentitySeed() },
            databaseKey: try loadOrCreate(account: "database-key") { try generateDbKey() }
        )
    }

    private static func loadOrCreate(account: String, make: () throws -> Data) throws -> Data {
        if let existing = try read(account: account) {
            return existing
        }
        let value = try make()
        try write(account: account, value: value)
        return value
    }

    private static func read(account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw KeychainError(status: status)
        }
    }

    private static func write(account: String, value: Data) throws {
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: value,
            // Readable by the login agent while the screen is locked, never synced or migrated.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }
}

struct KeychainError: Error, CustomStringConvertible {
    let status: OSStatus
    var description: String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
        return "Keychain error \(status): \(message)"
    }
}
