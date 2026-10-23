import CryptoKit
import Foundation
import Testing

@testable import SkerryKit

@Suite struct CipherAgilityTests {
    @Test func chaChaRoundTripsAndTheWrongCipherFails() throws {
        let key = SymmetricKey(size: .bits256)
        let secret = Data("harbor at dusk".utf8)
        let sealed = try NoteCrypto.seal(secret, key: key, cipher: .chaCha20Poly1305)
        #expect(try NoteCrypto.unseal(sealed, key: key, cipher: .chaCha20Poly1305) == secret)
        #expect(throws: NoteCrypto.CryptoError.decryptionFailed) {
            try NoteCrypto.unseal(sealed, key: key, cipher: .aesGCM)
        }
    }

    @Test func unsealAnyIdentifiesEitherCipher() throws {
        let key = SymmetricKey(size: .bits256)
        let secret = Data("same bytes either way".utf8)
        let aes = try NoteCrypto.seal(secret, key: key, cipher: .aesGCM)
        let chacha = try NoteCrypto.seal(secret, key: key, cipher: .chaCha20Poly1305)
        #expect(try NoteCrypto.unsealAny(aes, key: key) == secret)
        #expect(try NoteCrypto.unsealAny(chacha, key: key) == secret)
        #expect(throws: NoteCrypto.CryptoError.decryptionFailed) {
            try NoteCrypto.unsealAny(aes, key: SymmetricKey(size: .bits256))
        }
    }

    @Test func chaChaEnvelopeIsVersionThreeAndRoundTrips() throws {
        let key = SymmetricKey(size: .bits256)
        var note = Note()
        note.metadata.id = UUID()
        note.metadata.title = "Quiet plans"
        note.body = "the body"
        let envelope = try EncryptedNote.seal(note, key: key, cipher: .chaCha20Poly1305)
        let text = FrontMatter.serializeNote(envelope)
        #expect(text.contains("encv: 3"))
        #expect(text.contains("alg: chacha20poly1305"))
        #expect(EncryptedNote.usesMasterKey(envelope))
        let reopened = try EncryptedNote.unseal(FrontMatter.parseNote(text), key: key)
        #expect(reopened.metadata.title == "Quiet plans")
        #expect(reopened.body == "the body")
        #expect(!reopened.metadata.unknown.contains { $0.key == "alg" })
    }

    @Test func aesEnvelopesStayVersionTwo() throws {
        let key = SymmetricKey(size: .bits256)
        var note = Note()
        note.metadata.id = UUID()
        note.body = "compat matters"
        let envelope = try EncryptedNote.seal(note, key: key)
        let text = FrontMatter.serializeNote(envelope)
        #expect(text.contains("encv: 2"))
        #expect(!text.contains("alg:"))
        #expect(try EncryptedNote.unseal(envelope, key: key).body == "compat matters")
    }

    @Test func chaChaWrappingRecordsItselfAndUnlocks() throws {
        VaultKey.kdfTestOverride = (memory: 64, passes: 1, lanes: 1)
        VaultKey.sealingCipher = .chaCha20Poly1305
        defer { VaultKey.sealingCipher = .aesGCM }
        let (master, keyfile) = try VaultKey.create(passphrase: "cipher choice phrase")
        #expect(keyfile.passphrase.cipher == "chacha20poly1305")
        #expect(try VaultKey.unlock(keyfile, passphrase: "cipher choice phrase") == master)
    }

    @Test func unknownWrappingCipherIsRefused() throws {
        VaultKey.kdfTestOverride = (memory: 64, passes: 1, lanes: 1)
        let (_, keyfile) = try VaultKey.create(passphrase: "future cipher")
        var future = keyfile
        future.passphrase.cipher = "rot13-supreme"
        #expect(throws: VaultKey.VaultError.unsupportedVersion) {
            try VaultKey.unlock(future, passphrase: "future cipher")
        }
    }

    @Test func mixedCipherSyncConverges() async throws {
        let key = SymmetricKey(size: .bits256)
        let deviceA = try SyncDrive.makeLibrary()
        let deviceB = try SyncDrive.makeLibrary()
        let remoteFolder = try SyncDrive.makeLibrary()
        let remote = FolderSyncRemote(base: remoteFolder)

        try SyncDrive.write("from aes device", to: "a.md", in: deviceA)
        _ = try await SyncEngine.sync(library: deviceA, remote: remote, key: key)

        try SyncDrive.write("from chacha device", to: "b.md", in: deviceB)
        _ = try await SyncEngine.sync(
            library: deviceB, remote: remote, key: key, cipher: .chaCha20Poly1305
        )
        let back = try await SyncEngine.sync(library: deviceA, remote: remote, key: key)
        #expect(back.downloaded == 1)
        #expect(SyncDrive.read("b.md", in: deviceA) == "from chacha device")
        #expect(SyncDrive.read("a.md", in: deviceB) == "from aes device")
    }
}
