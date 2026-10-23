import CryptoKit
import Foundation
import Testing

@testable import SkerryKit

@Suite struct VaultKeyTests {
    /// Shrinks the Argon2 cost so every wrap in the suite runs in milliseconds.
    init() {
        VaultKey.kdfTestOverride = (memory: 64, passes: 1, lanes: 1)
    }

    @Test func createThenUnlockReturnsSameMasterKey() throws {
        let (master, keyfile) = try VaultKey.create(passphrase: "correct horse staple")
        #expect(try VaultKey.unlock(keyfile, passphrase: "correct horse staple") == master)
    }

    @Test func wrongPassphraseThrowsWrongSecret() throws {
        let (_, keyfile) = try VaultKey.create(passphrase: "the right one")
        #expect(throws: VaultKey.VaultError.wrongSecret) {
            try VaultKey.unlock(keyfile, passphrase: "the wrong one")
        }
    }

    @Test func changingPassphraseKeepsTheMasterKey() throws {
        let (master, keyfile) = try VaultKey.create(passphrase: "old passphrase")
        let updated = try VaultKey.changePassphrase(keyfile, master: master, to: "new passphrase")
        #expect(try VaultKey.unlock(updated, passphrase: "new passphrase") == master)
        #expect(throws: VaultKey.VaultError.wrongSecret) {
            try VaultKey.unlock(updated, passphrase: "old passphrase")
        }
    }

    @Test func recoveryCodeUnlocksAndIgnoresCaseAndDashes() throws {
        let (master, keyfile) = try VaultKey.create(passphrase: "primary")
        let (code, withRecovery) = try VaultKey.addRecovery(keyfile, master: master)
        #expect(code.contains("-"))
        #expect(try VaultKey.unlock(withRecovery, recovery: code) == master)
        #expect(try VaultKey.unlock(withRecovery, recovery: code.lowercased()) == master)
        #expect(try VaultKey.unlock(withRecovery, recovery: code.replacingOccurrences(of: "-", with: " ")) == master)
    }

    @Test func keyfileRoundTripsThroughJSON() throws {
        let (master, keyfile) = try VaultKey.create(passphrase: "serialize me")
        let decoded = try VaultKey.decode(VaultKey.encode(keyfile))
        #expect(decoded == keyfile)
        #expect(try VaultKey.unlock(decoded, passphrase: "serialize me") == master)
    }

    @Test func decodeRejectsAnUnknownVersion() throws {
        let (_, keyfile) = try VaultKey.create(passphrase: "future")
        var future = keyfile
        future.version = 99
        let data = try VaultKey.encode(future)
        #expect(throws: VaultKey.VaultError.unsupportedVersion) {
            try VaultKey.decode(data)
        }
    }

    @Test func wrongRecoveryCodeThrowsWrongSecret() throws {
        let (master, keyfile) = try VaultKey.create(passphrase: "primary")
        let (_, withRecovery) = try VaultKey.addRecovery(keyfile, master: master)
        #expect(throws: VaultKey.VaultError.wrongSecret) {
            try VaultKey.unlock(withRecovery, recovery: "00000-00000-00000-00000")
        }
    }

    @Test func recoveryUnlockSurvivesAPassphraseChange() throws {
        // Recovery must keep working after the passphrase is re-wrapped, since the whole point is
        // a second, independent way to the same master key.
        let (master, keyfile) = try VaultKey.create(passphrase: "first")
        let (code, withRecovery) = try VaultKey.addRecovery(keyfile, master: master)
        let rekeyed = try VaultKey.changePassphrase(withRecovery, master: master, to: "second")
        #expect(try VaultKey.unlock(rekeyed, recovery: code) == master)
        #expect(try VaultKey.unlock(rekeyed, passphrase: "second") == master)
    }
}
