import CryptoKit
import Foundation

/// EncryptedNote seals a note into an opaque on-disk envelope and unseals it back.
///
/// Body-only encryption still leaves the title, tags, and file name readable on disk. A
/// sealed note instead keeps only its id and the `encrypted` marker in plain front matter and
/// moves everything else, title and tags and dates and body, into the ciphertext. Clients
/// store the envelope under an opaque id-based file name, so the only thing an observer with
/// file access learns is that an encrypted note exists.
public enum EncryptedNote {
    /// Front matter key marking an envelope sealed under the vault master key.
    static let versionKey = "encv"
    /// Version marker for the AES-GCM master-key format.
    static let versionAES = "2"
    /// Version marker for envelopes that also name their cipher.
    static let versionTagged = "3"
    /// Front matter key naming the cipher on version 3 envelopes.
    static let cipherKey = "alg"

    /// Whether an envelope is sealed under the vault master key rather than the passphrase.
    public static func usesMasterKey(_ envelope: Note) -> Bool {
        envelope.metadata.unknown.contains {
            $0.key == versionKey && ($0.rawValue == versionAES || $0.rawValue == versionTagged)
        }
    }

    /// Kept name for the AES master-key check; version 3 envelopes count too.
    public static func isVersion2(_ envelope: Note) -> Bool {
        usesMasterKey(envelope)
    }

    /// The cipher a master-key envelope is sealed with.
    static func cipher(of envelope: Note) -> NoteCrypto.Cipher {
        let named = envelope.metadata.unknown.first { $0.key == cipherKey }?.rawValue
        return named.flatMap(NoteCrypto.Cipher.init(rawValue:)) ?? .aesGCM
    }

    /// Seals a note under the vault master key. AES-GCM writes the version 2 envelope every
    /// client reads; another cipher writes version 3 with the cipher named in front matter.
    public static func seal(
        _ note: Note, key: SymmetricKey, cipher: NoteCrypto.Cipher = .aesGCM
    ) throws -> Note {
        var inner = note
        inner.metadata.id = nil
        inner.metadata.encrypted = false
        inner.metadata.unknown.removeAll { $0.key == versionKey || $0.key == cipherKey }
        let plaintext = FrontMatter.serializeNote(inner)
        let blob = try NoteCrypto.seal(Data(plaintext.utf8), key: key, cipher: cipher)
            .base64EncodedString()
        var envelope = Note()
        envelope.metadata.id = note.metadata.id
        envelope.metadata.encrypted = true
        if cipher == .aesGCM {
            envelope.metadata.unknown = [(key: versionKey, rawValue: versionAES)]
        } else {
            envelope.metadata.unknown = [
                (key: versionKey, rawValue: versionTagged),
                (key: cipherKey, rawValue: cipher.rawValue),
            ]
        }
        envelope.body = blob
        return envelope
    }

    /// Unseals a master-key envelope, honoring the cipher it names.
    public static func unseal(_ envelope: Note, key: SymmetricKey) throws -> Note {
        let trimmed = envelope.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: trimmed) else { throw NoteCrypto.CryptoError.malformed }
        let plaintext = try NoteCrypto.unseal(data, key: key, cipher: cipher(of: envelope))
        var inner = FrontMatter.parseNote(String(decoding: plaintext, as: UTF8.self))
        var merged = envelope.metadata
        if let title = inner.metadata.title { merged.title = title }
        if !inner.metadata.tags.isEmpty { merged.tags = inner.metadata.tags }
        merged.starred = merged.starred || inner.metadata.starred
        merged.pinned = merged.pinned || inner.metadata.pinned
        merged.archived = merged.archived || inner.metadata.archived
        merged.locked = merged.locked || inner.metadata.locked
        if let created = inner.metadata.created { merged.created = created }
        if let updated = inner.metadata.updated { merged.updated = updated }
        if !inner.metadata.unknown.isEmpty { merged.unknown = inner.metadata.unknown }
        merged.unknown.removeAll { $0.key == versionKey || $0.key == cipherKey }
        merged.encrypted = true
        inner.metadata = merged
        return inner
    }

    /// Seals a plaintext note into an envelope whose body is the encrypted inner document.
    ///
    /// The returned note carries only `id` and `encrypted: true` in its metadata; its body is
    /// the base64 blob. Serializing the envelope yields the exact file to write to disk.
    public static func seal(_ note: Note, passphrase: String) throws -> Note {
        var inner = note
        inner.metadata.id = nil
        inner.metadata.encrypted = false
        let plaintext = FrontMatter.serializeNote(inner)
        let blob = try NoteCrypto.encrypt(plaintext, passphrase: passphrase)
        var envelope = Note()
        envelope.metadata.id = note.metadata.id
        envelope.metadata.encrypted = true
        envelope.body = blob
        return envelope
    }

    /// Unseals an envelope note back into its plaintext inner document.
    ///
    /// A new-format blob is a fully serialized inner note; an early body-only blob is raw text
    /// that parses to empty front matter. Either way the envelope's own metadata is folded in,
    /// so a note sealed before titles moved inside the ciphertext keeps its title, tags, and
    /// dates. The result stays marked encrypted, so re-sealing it produces an equivalent
    /// envelope. Throws when the passphrase is wrong or the blob is malformed.
    public static func unseal(_ envelope: Note, passphrase: String) throws -> Note {
        let plaintext = try NoteCrypto.decrypt(envelope.body, passphrase: passphrase)
        var inner = FrontMatter.parseNote(plaintext)
        var merged = envelope.metadata
        if let title = inner.metadata.title { merged.title = title }
        if !inner.metadata.tags.isEmpty { merged.tags = inner.metadata.tags }
        merged.starred = merged.starred || inner.metadata.starred
        merged.pinned = merged.pinned || inner.metadata.pinned
        merged.archived = merged.archived || inner.metadata.archived
        merged.locked = merged.locked || inner.metadata.locked
        if let created = inner.metadata.created { merged.created = created }
        if let updated = inner.metadata.updated { merged.updated = updated }
        if !inner.metadata.unknown.isEmpty { merged.unknown = inner.metadata.unknown }
        merged.encrypted = true
        inner.metadata = merged
        return inner
    }
}
