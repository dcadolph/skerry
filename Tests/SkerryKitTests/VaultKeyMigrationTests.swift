import CryptoKit
import Foundation
import Testing

@testable import SkerryKit

@Suite struct VaultKeyMigrationTests {
    /// Shrinks the Argon2 cost so every wrap in the suite runs in milliseconds.
    init() {
        VaultKey.kdfTestOverride = (memory: 64, passes: 1, lanes: 1)
    }

    /// Builds a version 2 keyfile exactly as the previous release wrote them: PBKDF2
    /// wrapping with no kdf field.
    private func makeLegacyKeyfile(
        passphrase: String, iterations: Int = 1000
    ) throws -> (SymmetricKey, VaultKey.Keyfile) {
        let master = SymmetricKey(size: .bits256)
        let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let kek = try NoteCrypto.deriveKey(
            passphrase: passphrase, salt: salt, iterations: iterations
        )
        let wrapped = try NoteCrypto.seal(master.withUnsafeBytes { Data($0) }, key: kek)
        let wrapping = VaultKey.Wrapping(
            salt: salt, iterations: iterations, wrapped: wrapped,
            kdf: nil, memory: nil, parallelism: nil
        )
        return (master, VaultKey.Keyfile(version: 2, passphrase: wrapping, recovery: nil))
    }

    @Test func newVaultsAreArgonVersionThree() throws {
        let (master, keyfile) = try VaultKey.create(passphrase: "fresh vault phrase")
        #expect(keyfile.version == 3)
        #expect(keyfile.passphrase.kdf == "argon2id")
        #expect(!VaultKey.needsKDFUpgrade(keyfile))
        #expect(try VaultKey.unlock(keyfile, passphrase: "fresh vault phrase") == master)
    }

    @Test func legacyKeyfilesStillUnlock() throws {
        let (master, legacy) = try makeLegacyKeyfile(passphrase: "old faithful")
        #expect(VaultKey.needsKDFUpgrade(legacy))
        #expect(try VaultKey.unlock(legacy, passphrase: "old faithful") == master)
        // Round trip through JSON without the new fields present.
        let decoded = try VaultKey.decode(VaultKey.encode(legacy))
        #expect(try VaultKey.unlock(decoded, passphrase: "old faithful") == master)
    }

    @Test func upgradeRewrapsUnderArgonAndKeepsTheMasterKey() throws {
        let (master, legacy) = try makeLegacyKeyfile(passphrase: "migrate me")
        let upgraded = try VaultKey.upgradeKDF(legacy, master: master, passphrase: "migrate me")
        #expect(upgraded.version == 3)
        #expect(upgraded.passphrase.kdf == "argon2id")
        #expect(!VaultKey.needsKDFUpgrade(upgraded))
        #expect(try VaultKey.unlock(upgraded, passphrase: "migrate me") == master)
        #expect(throws: VaultKey.VaultError.wrongSecret) {
            try VaultKey.unlock(upgraded, passphrase: "not the phrase")
        }
    }

    @Test func recoveryWrappingUpgradesSeparately() throws {
        let (master, legacy) = try makeLegacyKeyfile(passphrase: "primary")
        let (code, withRecovery) = try VaultKey.addRecovery(legacy, master: master)
        // The fresh recovery wrapping is argon already; force a legacy-shaped one.
        var legacyRecovery = withRecovery
        legacyRecovery.recovery?.kdf = nil
        let recoverySalt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let normalized = code.uppercased().filter { $0.isLetter || $0.isNumber }
        let kek = try NoteCrypto.deriveKey(
            passphrase: normalized, salt: recoverySalt, iterations: 1000
        )
        legacyRecovery.recovery = VaultKey.Wrapping(
            salt: recoverySalt, iterations: 1000,
            wrapped: try NoteCrypto.seal(master.withUnsafeBytes { Data($0) }, key: kek),
            kdf: nil, memory: nil, parallelism: nil
        )
        #expect(VaultKey.needsRecoveryKDFUpgrade(legacyRecovery))
        #expect(try VaultKey.unlock(legacyRecovery, recovery: code) == master)
        let upgraded = try VaultKey.upgradeRecoveryKDF(
            legacyRecovery, master: master, recovery: code
        )
        #expect(!VaultKey.needsRecoveryKDFUpgrade(upgraded))
        #expect(try VaultKey.unlock(upgraded, recovery: code) == master)
    }

    @Test func unknownKDFNamesAreRefused() throws {
        let (_, keyfile) = try VaultKey.create(passphrase: "future kdf")
        var future = keyfile
        future.passphrase.kdf = "quantum-mystery"
        #expect(throws: VaultKey.VaultError.unsupportedVersion) {
            try VaultKey.unlock(future, passphrase: "future kdf")
        }
    }
}
