import Foundation
import Testing

@testable import SkerryKit

@Suite struct Argon2Tests {
    /// Parses spaced hex into bytes.
    private func hex(_ text: String) -> Data {
        let cleaned = text.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
        var data = Data()
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            data.append(UInt8(cleaned[index..<next], radix: 16)!)
            index = next
        }
        return data
    }

    @Test func blake2bMatchesTheRFCVector() {
        // RFC 7693 appendix A: BLAKE2b-512("abc").
        let digest = Blake2b.hash(Data("abc".utf8), digestLength: 64)
        let expected = hex(
            """
            ba 80 a5 3f 98 1c 4d 0d 6a 27 97 b6 9f 12 f6 e9
            4c 21 2f 14 68 5a c4 b7 4b 12 bb 6f db ff a2 d1
            7d 87 c5 39 2a ab 79 2d c2 52 d5 de 45 33 cc 95
            18 d3 8a a8 db f1 92 5a b9 23 86 ed d4 00 99 23
            """
        )
        #expect(digest == expected)
    }

    @Test func blake2bHandlesEmptyAndLongInputs() {
        // RFC 7693 style checks: empty input and an input spanning several blocks.
        let empty = Blake2b.hash(Data(), digestLength: 64)
        #expect(empty.prefix(8) == hex("78 6a 02 f7 42 01 59 03"))
        let long = Data(repeating: 0xAB, count: 1000)
        #expect(Blake2b.hash(long, digestLength: 64).count == 64)
        #expect(Blake2b.hash(long, digestLength: 64) != Blake2b.hash(long, digestLength: 32))
    }

    @Test func argon2idMatchesTheRFCVector() {
        // RFC 9106 section 5.3: the Argon2id test vector.
        let tag = Argon2id.derive(
            password: Data(repeating: 0x01, count: 32),
            salt: Data(repeating: 0x02, count: 16),
            secret: Data(repeating: 0x03, count: 8),
            associated: Data(repeating: 0x04, count: 12),
            memoryKiB: 32, iterations: 3, parallelism: 4, outputLength: 32
        )
        let expected = hex(
            """
            0d 64 0d f5 8d 78 76 6c 08 c0 37 a3 4a 8b 53 c9
            d0 1e f0 45 2d 75 b6 5e b5 25 20 e9 6b 01 e6 59
            """
        )
        #expect(tag == expected)
    }

    @Test func derivationIsDeterministicAndSaltSensitive() {
        let password = Data("correct horse battery".utf8)
        let saltA = Data(repeating: 0x11, count: 16)
        let saltB = Data(repeating: 0x22, count: 16)
        let first = Argon2id.deriveKey(
            password: password, salt: saltA, memoryKiB: 64, iterations: 2,
            parallelism: 2, outputLength: 32
        )
        let again = Argon2id.deriveKey(
            password: password, salt: saltA, memoryKiB: 64, iterations: 2,
            parallelism: 2, outputLength: 32
        )
        let other = Argon2id.deriveKey(
            password: password, salt: saltB, memoryKiB: 64, iterations: 2,
            parallelism: 2, outputLength: 32
        )
        #expect(first == again)
        #expect(first != other)
        #expect(first.count == 32)
    }
}

@Suite struct ZeroizingSecretTests {
    @Test func valueRoundTripsAndWipes() {
        let secret = ZeroizingSecret("hunter2 passphrase")
        #expect(secret.value == "hunter2 passphrase")
        #expect(!secret.isEmpty)
        secret.wipe()
        #expect(secret.isEmpty)
        #expect(secret.value.isEmpty)
    }
}
