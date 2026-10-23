import CryptoKit
import Foundation
import Testing

@testable import SkerryKit

@Suite struct EncryptedNoteTests {
    /// Builds a note with explicit title, tags, and body for round-trip checks.
    private func sampleNote() -> Note {
        var metadata = Note.Metadata()
        metadata.id = UUID(uuidString: "7A0E38D2-4CBB-4E30-9A57-2A9F3D1B6C11")
        metadata.title = "Ferry timetable research"
        metadata.tags = ["travel", "scotland"]
        metadata.starred = true
        metadata.created = Date(timeIntervalSince1970: 1_700_000_000)
        metadata.updated = Date(timeIntervalSince1970: 1_700_001_000)
        return Note(metadata: metadata, body: "# Ferry timetable research\n\nSecret plans.")
    }

    @Test func roundTripPreservesEverything() throws {
        let note = sampleNote()
        let envelope = try EncryptedNote.seal(note, passphrase: "correct horse")
        let restored = try EncryptedNote.unseal(envelope, passphrase: "correct horse")
        #expect(restored.metadata.title == note.metadata.title)
        #expect(restored.metadata.tags == note.metadata.tags)
        #expect(restored.metadata.starred == note.metadata.starred)
        #expect(restored.metadata.created == note.metadata.created)
        #expect(restored.metadata.updated == note.metadata.updated)
        #expect(restored.metadata.id == note.metadata.id)
        #expect(restored.metadata.encrypted)
        #expect(restored.body == note.body)
    }

    @Test func envelopeExposesOnlyIdAndMarker() throws {
        let envelope = try EncryptedNote.seal(sampleNote(), passphrase: "key")
        #expect(envelope.metadata.encrypted)
        #expect(envelope.metadata.id == UUID(uuidString: "7A0E38D2-4CBB-4E30-9A57-2A9F3D1B6C11"))
        #expect(envelope.metadata.title == nil)
        #expect(envelope.metadata.tags.isEmpty)
    }

    @Test func serializedFileHidesTitleTagsAndBody() throws {
        let envelope = try EncryptedNote.seal(sampleNote(), passphrase: "key")
        let onDisk = FrontMatter.serializeNote(envelope)
        #expect(!onDisk.contains("Ferry timetable research"))
        #expect(!onDisk.contains("travel"))
        #expect(!onDisk.contains("scotland"))
        #expect(!onDisk.contains("Secret plans"))
        #expect(onDisk.contains("encrypted: true"))
    }

    @Test func sealedFileParsesBackToAnEnvelope() throws {
        let envelope = try EncryptedNote.seal(sampleNote(), passphrase: "key")
        let onDisk = FrontMatter.serializeNote(envelope)
        let parsed = FrontMatter.parseNote(onDisk)
        #expect(parsed.metadata.encrypted)
        #expect(parsed.metadata.title == nil)
        let restored = try EncryptedNote.unseal(parsed, passphrase: "key")
        #expect(restored.metadata.title == "Ferry timetable research")
        #expect(restored.body == "# Ferry timetable research\n\nSecret plans.")
    }

    @Test func wrongPassphraseFailsToUnseal() throws {
        let envelope = try EncryptedNote.seal(sampleNote(), passphrase: "right")
        #expect(throws: NoteCrypto.CryptoError.decryptionFailed) {
            try EncryptedNote.unseal(envelope, passphrase: "wrong")
        }
    }

    @Test func legacyBodyOnlyBlobKeepsEnvelopeMetadata() throws {
        // An early encrypted note stored the ciphertext of the body alone and kept the title
        // and tags in plain front matter. Unsealing it must recover all of that.
        let body = "# Secret\n\nCard 4242 4242 4242 4242."
        let blob = try NoteCrypto.encrypt(body, passphrase: "key")
        var metadata = Note.Metadata()
        metadata.id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")
        metadata.title = "My Secret"
        metadata.tags = ["private", "money"]
        metadata.starred = true
        metadata.encrypted = true
        let legacy = Note(metadata: metadata, body: blob)
        let restored = try EncryptedNote.unseal(legacy, passphrase: "key")
        #expect(restored.metadata.title == "My Secret")
        #expect(restored.metadata.tags == ["private", "money"])
        #expect(restored.metadata.starred)
        #expect(restored.metadata.id == metadata.id)
        #expect(restored.body == body)
    }

    @Test func titleFromHeadingSurvivesWhenNoExplicitTitle() throws {
        var metadata = Note.Metadata()
        metadata.id = UUID()
        let note = Note(metadata: metadata, body: "# Derived Heading\n\nBody text.")
        let envelope = try EncryptedNote.seal(note, passphrase: "key")
        #expect(!FrontMatter.serializeNote(envelope).contains("Derived Heading"))
        let restored = try EncryptedNote.unseal(envelope, passphrase: "key")
        #expect(restored.displayTitle == "Derived Heading")
    }

    @Test func masterKeyEnvelopeRoundTripsAndMarksVersion2() throws {
        let key = SymmetricKey(size: .bits256)
        let note = sampleNote()
        let envelope = try EncryptedNote.seal(note, key: key)
        #expect(EncryptedNote.isVersion2(envelope))
        #expect(envelope.metadata.title == nil)
        #expect(envelope.metadata.tags.isEmpty)
        #expect(envelope.metadata.id == note.metadata.id)
        let onDisk = FrontMatter.serializeNote(envelope)
        #expect(!onDisk.contains("Ferry timetable research"))
        #expect(onDisk.contains("encv: 2"))

        let restored = try EncryptedNote.unseal(envelope, key: key)
        #expect(restored.metadata.title == note.metadata.title)
        #expect(restored.metadata.tags == note.metadata.tags)
        #expect(restored.body == note.body)
        #expect(restored.metadata.id == note.metadata.id)
        #expect(restored.metadata.unknown.isEmpty)
        #expect(throws: NoteCrypto.CryptoError.self) {
            try EncryptedNote.unseal(envelope, key: SymmetricKey(size: .bits256))
        }
    }

    @Test func passphraseEnvelopeIsNotVersion2() throws {
        let v1 = try EncryptedNote.seal(sampleNote(), passphrase: "passphrase")
        #expect(!EncryptedNote.isVersion2(v1))
    }

    @Test func migratingFromV1ToV2PreservesTheNote() throws {
        // This mirrors the on-device upgrade: a passphrase-sealed note is read, then re-sealed
        // under a master key wrapped by the same passphrase, and must still round-trip.
        let note = sampleNote()
        let v1 = try EncryptedNote.seal(note, passphrase: "my passphrase")
        let (master, keyfile) = try VaultKey.create(passphrase: "my passphrase")
        let opened = try EncryptedNote.unseal(v1, passphrase: "my passphrase")
        let v2 = try EncryptedNote.seal(opened, key: master)
        #expect(EncryptedNote.isVersion2(v2))

        let unlockedKey = try VaultKey.unlock(keyfile, passphrase: "my passphrase")
        let restored = try EncryptedNote.unseal(v2, key: unlockedKey)
        #expect(restored.metadata.title == note.metadata.title)
        #expect(restored.metadata.tags == note.metadata.tags)
        #expect(restored.body == note.body)
        #expect(restored.metadata.id == note.metadata.id)
    }
}
