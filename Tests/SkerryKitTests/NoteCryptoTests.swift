import CryptoKit
import Foundation
import Testing

@testable import SkerryKit

@Suite struct NoteCryptoTests {
    @Test func roundTripReturnsPlaintext() throws {
        let secret = "# Private\n\nCard 4242 4242 4242 4242."
        let blob = try NoteCrypto.encrypt(secret, passphrase: "correct horse battery")
        #expect(blob != secret)
        let decrypted = try NoteCrypto.decrypt(blob, passphrase: "correct horse battery")
        #expect(decrypted == secret)
    }

    @Test func wrongPassphraseFails() throws {
        let blob = try NoteCrypto.encrypt("secret", passphrase: "right")
        #expect(throws: NoteCrypto.CryptoError.decryptionFailed) {
            try NoteCrypto.decrypt(blob, passphrase: "wrong")
        }
    }

    @Test func eachEncryptionUsesFreshSaltAndNonce() throws {
        let one = try NoteCrypto.encrypt("same", passphrase: "key")
        let two = try NoteCrypto.encrypt("same", passphrase: "key")
        #expect(one != two)
        #expect(try NoteCrypto.decrypt(one, passphrase: "key") == "same")
        #expect(try NoteCrypto.decrypt(two, passphrase: "key") == "same")
    }

    @Test func malformedBlobThrows() {
        #expect(throws: NoteCrypto.CryptoError.self) {
            try NoteCrypto.decrypt("not base64 %%%", passphrase: "key")
        }
        #expect(throws: NoteCrypto.CryptoError.self) {
            try NoteCrypto.decrypt("YWJj", passphrase: "key")
        }
    }

    @Test func unicodeSurvivesRoundTrip() throws {
        let text = "emoji 🐟 and accents café — kept"
        let blob = try NoteCrypto.encrypt(text, passphrase: "pass")
        #expect(try NoteCrypto.decrypt(blob, passphrase: "pass") == text)
    }

    @Test func sealAndUnsealWithAKeyRoundTrips() throws {
        let key = SymmetricKey(size: .bits256)
        let data = Data("sealed under the master key".utf8)
        let sealed = try NoteCrypto.seal(data, key: key)
        #expect(try NoteCrypto.unseal(sealed, key: key) == data)
        #expect(throws: NoteCrypto.CryptoError.self) {
            try NoteCrypto.unseal(sealed, key: SymmetricKey(size: .bits256))
        }
    }

    @Test func sealAndUnsealRawBytes() throws {
        let bytes = Data((0..<600).map { UInt8($0 & 0xFF) })
        let sealed = try NoteCrypto.seal(bytes, passphrase: "pw")
        #expect(sealed != bytes)
        #expect(try NoteCrypto.unseal(sealed, passphrase: "pw") == bytes)
        #expect(throws: NoteCrypto.CryptoError.self) {
            try NoteCrypto.unseal(sealed, passphrase: "nope")
        }
    }

    @Test func isSealedBlobTellsCiphertextFromCleartext() throws {
        let blob = try NoteCrypto.encrypt("secret note body", passphrase: "passphrase")
        #expect(NoteCrypto.isSealedBlob(blob))
        #expect(!NoteCrypto.isSealedBlob("# A Title\n\nplain prose"))
        #expect(!NoteCrypto.isSealedBlob(""))
        // Valid base64 but far too short to be salt, nonce, and tag.
        #expect(!NoteCrypto.isSealedBlob("YWJj"))
    }
}
