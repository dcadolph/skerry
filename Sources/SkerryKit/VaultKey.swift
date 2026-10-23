import CryptoKit
import Foundation

/// VaultKey is a random master key wrapped by a passphrase, the core of Skerry's key hierarchy.
///
/// A random 256-bit master key encrypts notes and backups. That master key is itself sealed under
/// a key-encryption key derived from the passphrase, so three things become possible: changing the
/// passphrase only re-wraps the master key rather than re-encrypting everything, a recovery code
/// can wrap the same master key as a second way in, and the app can hold the master key in memory
/// instead of the passphrase. Because the slow key derivation runs once at unlock rather than per
/// note, the iteration count can be set high.
public enum VaultKey {
    /// Errors raised by vault operations.
    public enum VaultError: Error, Equatable {
        /// The keyfile could not be parsed.
        case malformed
        /// The passphrase or recovery code was wrong.
        case wrongSecret
        /// The keyfile version is not understood.
        case unsupportedVersion
    }

    /// Current keyfile version. Version 3 added named KDFs with Argon2id as the default;
    /// version 2 keyfiles still open and upgrade in place after a successful unlock.
    public static let version = 3
    /// Versions this build can open.
    static let supportedVersions = 2...3
    /// PBKDF2 iterations for version 2 wrappings, kept for reading and upgrades.
    public static let kdfIterations = 600_000
    /// Argon2id parameters for new wrappings: RFC 9106's memory-constrained
    /// recommendation, 64 MiB with 3 passes over 4 lanes.
    public static let argonMemoryKiB = 65_536
    /// Argon2id pass count for new wrappings.
    public static let argonPasses = 3
    /// Argon2id lane count for new wrappings.
    public static let argonLanes = 4
    /// Test hook shrinking Argon2 parameters so suites stay fast; nil in production.
    nonisolated(unsafe) static var kdfTestOverride: (memory: Int, passes: Int, lanes: Int)?
    /// Salt length in bytes for a wrapping.
    private static let saltLength = 16
    /// Master key length in bytes.
    private static let masterKeyLength = 32

    /// One wrapping of the master key under a secret, passphrase or recovery code.
    public struct Wrapping: Equatable, Sendable, Codable {
        /// Salt for the key-encryption-key derivation.
        public var salt: Data
        /// Work parameter: PBKDF2 iteration count, or Argon2 pass count.
        public var iterations: Int
        /// The master key sealed under the derived key: nonce, ciphertext, and tag.
        public var wrapped: Data
        /// KDF deriving the key-encryption key; nil means the version 2 PBKDF2.
        public var kdf: String?
        /// Argon2 memory cost in KiB; nil outside Argon2 wrappings.
        public var memory: Int?
        /// Argon2 lane count; nil outside Argon2 wrappings.
        public var parallelism: Int?
        /// AEAD sealing the wrapped master key; nil means AES-256-GCM.
        public var cipher: String?
    }

    /// A vault keyfile: the wrapped master key, optionally with a recovery wrapping.
    public struct Keyfile: Equatable, Sendable, Codable {
        /// Format version.
        public var version: Int
        /// Master key wrapped under the passphrase.
        public var passphrase: Wrapping
        /// Master key wrapped under a recovery code, when one has been set.
        public var recovery: Wrapping?
    }

    /// Creates a new vault: a random master key wrapped by the passphrase.
    public static func create(passphrase: String) throws -> (key: SymmetricKey, keyfile: Keyfile) {
        let master = SymmetricKey(size: .bits256)
        let wrapping = try wrap(master: master, secret: passphrase)
        return (master, Keyfile(version: version, passphrase: wrapping, recovery: nil))
    }

    /// Unwraps the master key from a keyfile using the passphrase.
    public static func unlock(_ keyfile: Keyfile, passphrase: String) throws -> SymmetricKey {
        guard supportedVersions.contains(keyfile.version) else {
            throw VaultError.unsupportedVersion
        }
        return try unwrap(keyfile.passphrase, secret: passphrase)
    }

    /// Unwraps the master key using the recovery code.
    public static func unlock(_ keyfile: Keyfile, recovery code: String) throws -> SymmetricKey {
        guard supportedVersions.contains(keyfile.version) else {
            throw VaultError.unsupportedVersion
        }
        guard let recovery = keyfile.recovery else { throw VaultError.wrongSecret }
        return try unwrap(recovery, secret: normalizeRecovery(code))
    }

    /// Whether a keyfile's passphrase wrapping still uses the version 2 PBKDF2.
    public static func needsKDFUpgrade(_ keyfile: Keyfile) -> Bool {
        (keyfile.passphrase.kdf ?? "pbkdf2") != "argon2id"
    }

    /// Whether a keyfile's recovery wrapping still uses the version 2 PBKDF2.
    public static func needsRecoveryKDFUpgrade(_ keyfile: Keyfile) -> Bool {
        guard let recovery = keyfile.recovery else { return false }
        return (recovery.kdf ?? "pbkdf2") != "argon2id"
    }

    /// Re-wraps the passphrase wrapping under Argon2id after a successful unlock. The
    /// recovery wrapping upgrades separately, the next time the code itself is used.
    public static func upgradeKDF(
        _ keyfile: Keyfile, master: SymmetricKey, passphrase: String
    ) throws -> Keyfile {
        var updated = keyfile
        updated.version = version
        updated.passphrase = try wrap(master: master, secret: passphrase)
        return updated
    }

    /// Re-wraps the recovery wrapping under Argon2id after a successful recovery unlock.
    public static func upgradeRecoveryKDF(
        _ keyfile: Keyfile, master: SymmetricKey, recovery code: String
    ) throws -> Keyfile {
        var updated = keyfile
        updated.version = version
        updated.recovery = try wrap(master: master, secret: normalizeRecovery(code))
        return updated
    }

    /// Re-wraps the master key under a new passphrase, keeping any recovery wrapping.
    public static func changePassphrase(
        _ keyfile: Keyfile, master: SymmetricKey, to newPassphrase: String
    ) throws -> Keyfile {
        var updated = keyfile
        updated.passphrase = try wrap(master: master, secret: newPassphrase)
        return updated
    }

    /// Adds or replaces a recovery wrapping and returns the printable code to show once.
    public static func addRecovery(
        _ keyfile: Keyfile, master: SymmetricKey
    ) throws -> (code: String, keyfile: Keyfile) {
        let code = try generateRecoveryCode()
        var updated = keyfile
        updated.recovery = try wrap(master: master, secret: normalizeRecovery(code))
        return (code, updated)
    }

    /// Encodes a keyfile to JSON bytes for storage. Throwing so a failed encode can never be
    /// written over a good keyfile as an empty file.
    public static func encode(_ keyfile: Keyfile) throws -> Data {
        do {
            return try JSONEncoder().encode(keyfile)
        } catch {
            throw VaultError.malformed
        }
    }

    /// Decodes a keyfile from JSON bytes, rejecting any version this build does not understand
    /// so a newer keyfile is never treated as a usable vault.
    public static func decode(_ data: Data) throws -> Keyfile {
        let keyfile: Keyfile
        do {
            keyfile = try JSONDecoder().decode(Keyfile.self, from: data)
        } catch {
            throw VaultError.malformed
        }
        guard supportedVersions.contains(keyfile.version) else {
            throw VaultError.unsupportedVersion
        }
        return keyfile
    }

    /// Wraps a master key under a secret with a fresh salt, using Argon2id.
    private static func wrap(master: SymmetricKey, secret: String) throws -> Wrapping {
        var salt = Data(count: saltLength)
        let generated = salt.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, saltLength, $0.baseAddress!)
        }
        guard generated == errSecSuccess else { throw VaultError.malformed }
        let memory = kdfTestOverride?.memory ?? argonMemoryKiB
        let passes = kdfTestOverride?.passes ?? argonPasses
        let lanes = kdfTestOverride?.lanes ?? argonLanes
        let kek = try deriveKEK(
            secret: secret, salt: salt, kdf: "argon2id",
            iterations: passes, memory: memory, parallelism: lanes
        )
        let masterBytes = master.withUnsafeBytes { Data($0) }
        let wrapped = try NoteCrypto.seal(masterBytes, key: kek, cipher: sealingCipher)
        return Wrapping(
            salt: salt, iterations: passes, wrapped: wrapped,
            kdf: "argon2id", memory: memory, parallelism: lanes,
            cipher: sealingCipher == .aesGCM ? nil : sealingCipher.rawValue
        )
    }

    /// Cipher new wrappings seal with; the app sets this from the library's choice.
    nonisolated(unsafe) public static var sealingCipher: NoteCrypto.Cipher = .aesGCM

    /// Derives the key-encryption key with a wrapping's named KDF.
    private static func deriveKEK(
        secret: String, salt: Data, kdf: String?, iterations: Int,
        memory: Int?, parallelism: Int?
    ) throws -> SymmetricKey {
        switch kdf ?? "pbkdf2" {
        case "argon2id":
            let raw = Argon2id.deriveKey(
                password: Data(secret.utf8), salt: salt,
                memoryKiB: memory ?? argonMemoryKiB, iterations: iterations,
                parallelism: parallelism ?? argonLanes, outputLength: masterKeyLength
            )
            return SymmetricKey(data: raw)
        case "pbkdf2":
            return try NoteCrypto.deriveKey(passphrase: secret, salt: salt, iterations: iterations)
        default:
            // An unknown KDF means a newer client wrote this keyfile.
            throw VaultError.unsupportedVersion
        }
    }

    /// Unwraps a master key from a wrapping, mapping crypto failures to a wrong-secret error.
    private static func unwrap(_ wrapping: Wrapping, secret: String) throws -> SymmetricKey {
        let kek = try deriveKEK(
            secret: secret, salt: wrapping.salt, kdf: wrapping.kdf,
            iterations: wrapping.iterations, memory: wrapping.memory,
            parallelism: wrapping.parallelism
        )
        guard let cipher = wrapping.cipher.map(NoteCrypto.Cipher.init(rawValue:)) ?? .aesGCM
        else {
            // An unknown cipher name means a newer client wrote this keyfile.
            throw VaultError.unsupportedVersion
        }
        do {
            let raw = try NoteCrypto.unseal(wrapping.wrapped, key: kek, cipher: cipher)
            guard raw.count == masterKeyLength else { throw VaultError.malformed }
            return SymmetricKey(data: raw)
        } catch is NoteCrypto.CryptoError {
            throw VaultError.wrongSecret
        }
    }

    /// Generates a printable recovery code in groups of Crockford base32 characters.
    private static func generateRecoveryCode() -> String {
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        var bytes = Data(count: 20)
        _ = bytes.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 20, $0.baseAddress!)
        }
        let chars = bytes.map { alphabet[Int($0) % alphabet.count] }
        var groups: [String] = []
        var index = 0
        while index < chars.count {
            groups.append(String(chars[index..<min(index + 5, chars.count)]))
            index += 5
        }
        return groups.joined(separator: "-")
    }

    /// Normalizes a recovery code so separators and case do not matter on entry.
    private static func normalizeRecovery(_ code: String) -> String {
        code.uppercased().filter { $0.isLetter || $0.isNumber }
    }
}
