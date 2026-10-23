import Foundation

/// TagColor maps a tag name to a stable slot in a color palette, so a tag wears the same
/// color everywhere it appears without anyone having to assign one. The mapping is a plain
/// content hash, so it is identical across launches and across devices, unlike Swift's
/// per-process `hashValue`. The palette itself lives in the app; the kit only picks the slot.
public enum TagColor {
    /// The palette slot for a tag name, in the range `0..<count`. Case-insensitive, so
    /// `Work` and `work` share a color. Returns zero for an empty palette.
    public static func paletteIndex(for name: String, count: Int) -> Int {
        guard count > 0 else { return 0 }
        // FNV-1a over the lowercased bytes: small, stable, and well spread for short strings.
        var hash: UInt32 = 2_166_136_261
        for byte in name.lowercased().utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return Int(hash % UInt32(count))
    }
}
