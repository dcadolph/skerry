import Foundation

/// ZeroizingSecret holds a secret's bytes and zeroes them on wipe and on deallocation,
/// shrinking how long a passphrase lingers in memory after the vault locks. Transient
/// String copies made at use sites still exist; this closes the long-lived one.
public final class ZeroizingSecret {
    /// Secret bytes, zeroed in place on wipe.
    private var bytes: [UInt8]

    /// Wraps a secret string.
    public init(_ value: String) {
        bytes = Array(value.utf8)
    }

    /// The secret as a string; each call makes a fresh transient copy.
    public var value: String {
        String(decoding: bytes, as: UTF8.self)
    }

    /// Whether the secret has been wiped.
    public var isEmpty: Bool { bytes.isEmpty }

    /// Overwrites the bytes and drops them.
    public func wipe() {
        for index in bytes.indices {
            bytes[index] = 0
        }
        bytes = []
    }

    deinit {
        for index in bytes.indices {
            bytes[index] = 0
        }
    }
}
