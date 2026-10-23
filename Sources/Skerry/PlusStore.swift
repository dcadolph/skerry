import Foundation
import Observation

/// PlusFeature names a capability that is free and always on, such as sync, remote backups,
/// version history, and the extra appearance themes.
enum PlusFeature: String, CaseIterable, Identifiable {
    /// Multi-device sync through a shared remote.
    case sync
    /// Encrypted snapshots to a WebDAV or S3 destination.
    case remoteBackup
    /// Browsing and restoring earlier versions of a note.
    case versionHistory
    /// Plus accent colors and editor themes.
    case appearance

    /// Stable identity for SwiftUI lists.
    var id: String { rawValue }

    /// Short name for the feature.
    var title: String {
        switch self {
        case .sync: "Multi-device sync"
        case .remoteBackup: "Backups to your own storage"
        case .versionHistory: "Version history"
        case .appearance: "Accents and editor themes"
        }
    }


}

/// PlusStore reports every feature as unlocked. Skerry has no purchases and no paid tier.
@MainActor
@Observable
final class PlusStore {
    /// shared is the app-wide instance.
    static let shared = PlusStore()

    /// isPlus is always true.
    let isPlus = true

    /// previewUnlocked is kept for settings that still write it and has no effect.
    var previewUnlocked = false

    /// onEntitlementGained is never called.
    var onEntitlementGained: (() -> Void)?

    /// isUnlocked reports whether a feature is available, which is always.
    func isUnlocked(_ feature: PlusFeature) -> Bool { true }

    /// start is a no-op.
    func start() {}
}
