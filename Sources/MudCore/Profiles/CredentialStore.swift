import Foundation
import os.log
import Security

/// Stores secrets (currently autologin passwords) outside the plaintext
/// profile document.
///
/// `WorldProfile` keeps the *username* (not secret) and the autologin
/// prompt patterns in `profiles.json`; the password lives here, keyed by
/// a stable account string — by convention `"<profileID>.password"`. The
/// production implementation is ``KeychainStore``; tests use
/// ``InMemoryCredentialStore`` so they never touch the system keychain.
///
/// Methods are intentionally non-throwing: the UI treats credential
/// storage as best-effort and a failure to persist a password should not
/// crash the editor. ``KeychainStore`` logs failures via `os.log`.
public protocol CredentialStore: Sendable {
    /// Fetch the stored password for `account`, or `nil` if none exists
    /// (or the lookup failed).
    func password(forAccount account: String) -> String?

    /// Store (or overwrite) `password` for `account`. Passing an empty
    /// string removes the entry instead — there is no point keeping a
    /// blank secret around.
    func setPassword(_ password: String, forAccount account: String)

    /// Delete any stored password for `account`. Idempotent.
    func removePassword(forAccount account: String)
}

/// Keychain-backed ``CredentialStore`` using a generic-password item per
/// account under a single service name.
///
/// The app runs without the sandbox, so items land in the user's login
/// keychain without needing a keychain-access-group entitlement.
public struct KeychainStore: CredentialStore {
    /// `kSecAttrService` for every item this store manages. Defaults to
    /// the app's bundle identifier.
    public let service: String

    private static let log = Logger(
        subsystem: "com.proteles.MudCore",
        category: "Keychain"
    )

    public init(service: String = "com.proteles.ProtelesApp") {
        self.service = service
    }

    public func password(forAccount account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            Self.log.error("keychain read failed for \(account, privacy: .public): \(status)")
            return nil
        }
    }

    public func setPassword(_ password: String, forAccount account: String) {
        guard !password.isEmpty else {
            removePassword(forAccount: account)
            return
        }
        let data = Data(password.utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let probe = SecItemCopyMatching(base as CFDictionary, nil)
        let status: OSStatus
        if probe == errSecSuccess {
            status = SecItemUpdate(
                base as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
        } else {
            var add = base
            add[kSecValueData as String] = data
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status != errSecSuccess {
            Self.log.error("keychain write failed for \(account, privacy: .public): \(status)")
        }
    }

    public func removePassword(forAccount account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            Self.log.error("keychain delete failed for \(account, privacy: .public): \(status)")
        }
    }
}

/// In-memory ``CredentialStore`` for tests and previews. Thread-safe via
/// an internal lock so it satisfies `Sendable` without an actor hop.
public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private var storage: [String: String] = [:]
    private let lock = NSLock()

    public init() {}

    public func password(forAccount account: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[account]
    }

    public func setPassword(_ password: String, forAccount account: String) {
        lock.lock(); defer { lock.unlock() }
        if password.isEmpty {
            storage[account] = nil
        } else {
            storage[account] = password
        }
    }

    public func removePassword(forAccount account: String) {
        lock.lock(); defer { lock.unlock() }
        storage[account] = nil
    }
}
