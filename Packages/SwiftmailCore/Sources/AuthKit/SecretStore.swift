import Foundation
import Security
import Synchronization

/// Where refresh tokens live. The Keychain in the app, in memory in tests.
public protocol SecretStore: Sendable {
    func save(_ secret: String, account: String) throws
    func load(account: String) throws -> String?
    func delete(account: String) throws
}

/// Refresh tokens in the Keychain under service `app.swiftmail.oauth` and account `<sub>`.
///
/// Uses the data protection keychain when the app's entitlements allow it, so
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` applies. A build signed without a
/// provisioning profile lacks the keychain access group, so it falls back to the
/// login keychain, which is still per-app through the item's access control list.
public struct KeychainStore: SecretStore {
    public static let service = "app.swiftmail.oauth"

    public init() {}

    public func save(_ secret: String, account: String) throws {
        let data = Data(secret.utf8)
        for useDataProtection in [true, false] {
            var query = baseQuery(account: account, dataProtection: useDataProtection)
            let deleteStatus = SecItemDelete(query as CFDictionary)
            if deleteStatus == errSecMissingEntitlement {
                continue
            }
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = SecItemAdd(query as CFDictionary, nil)
            if status == errSecMissingEntitlement {
                continue
            }
            guard status == errSecSuccess else { throw AuthError.keychain(status) }
            return
        }
        throw AuthError.keychain(errSecMissingEntitlement)
    }

    public func load(account: String) throws -> String? {
        for useDataProtection in [true, false] {
            var query = baseQuery(account: account, dataProtection: useDataProtection)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            switch status {
            case errSecSuccess:
                guard let data = result as? Data else { return nil }
                return String(bytes: data, encoding: .utf8)
            case errSecItemNotFound, errSecMissingEntitlement:
                continue
            default:
                throw AuthError.keychain(status)
            }
        }
        return nil
    }

    public func delete(account: String) throws {
        for useDataProtection in [true, false] {
            let status = SecItemDelete(baseQuery(account: account, dataProtection: useDataProtection) as CFDictionary)
            guard [errSecSuccess, errSecItemNotFound, errSecMissingEntitlement].contains(status) else {
                throw AuthError.keychain(status)
            }
        }
    }

    private func baseQuery(account: String, dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
        if dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }
}

/// In-memory store for tests and previews.
public final class InMemorySecretStore: SecretStore {
    private let storage = Mutex<[String: String]>([:])

    public init(_ initial: [String: String] = [:]) {
        storage.withLock { $0 = initial }
    }

    public func save(_ secret: String, account: String) throws {
        storage.withLock { $0[account] = secret }
    }

    public func load(account: String) throws -> String? {
        storage.withLock { $0[account] }
    }

    public func delete(account: String) throws {
        _ = storage.withLock { $0.removeValue(forKey: account) }
    }
}
