import Foundation
import LocalAuthentication
import Security

/// KeychainVault stores the encryption passphrase in the keychain behind biometrics.
///
/// The passphrase itself never touches disk in the clear: it lives in the keychain guarded
/// by Face ID, Touch ID, or the device passcode, and is only released after the owner
/// authenticates. Losing the passphrase means the encrypted notes cannot be recovered,
/// which is the point.
enum KeychainVault {
    /// Account name under which the passphrase is stored.
    private static let account = "vault.passphrase"
    /// Service name namespacing the keychain item to this app.
    private static let service = "com.dcadolph.skerry"

    /// Whether a passphrase has been set up.
    static func exists() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: service,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,
            kSecReturnData as String: false,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    /// Stores a passphrase, replacing any existing one, guarded by biometrics.
    ///
    /// The item is added, or its value updated when one already exists, without a destructive
    /// delete first, so a failure can never leave the keychain empty while a keyfile on disk still
    /// expects the passphrase.
    @discardableResult
    static func store(_ passphrase: String) -> Bool {
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .userPresence, nil
        ) else { return false }
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: service,
        ]
        var insert = identity
        insert[kSecValueData as String] = Data(passphrase.utf8)
        insert[kSecAttrAccessControl as String] = access
        let status = SecItemAdd(insert as CFDictionary, nil)
        if status == errSecSuccess { return true }
        guard status == errSecDuplicateItem else { return false }
        let update: [String: Any] = [kSecValueData as String: Data(passphrase.utf8)]
        return SecItemUpdate(identity as CFDictionary, update as CFDictionary) == errSecSuccess
    }

    /// Fetches the passphrase, prompting the owner to authenticate first.
    static func fetch(reason: String) -> String? {
        let context = LAContext()
        context.localizedReason = reason
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecUseAuthenticationContext as String: context,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Removes the stored passphrase.
    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Stores a secret under an account, readable after first unlock without a biometric
    /// prompt, so a background backup can use it. Used for the WebDAV password.
    @discardableResult
    static func storeSecret(_ value: String, account secretAccount: String) -> Bool {
        deleteSecret(account: secretAccount)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: secretAccount,
            kSecAttrService as String: service,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    /// Fetches a secret stored with ``storeSecret(_:account:)``.
    static func fetchSecret(account secretAccount: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: secretAccount,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Removes a secret stored with ``storeSecret(_:account:)``.
    static func deleteSecret(account secretAccount: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: secretAccount,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
