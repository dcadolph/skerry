import Foundation

/// WidgetNote is one row a widget can show. Only plain, unlocked notes ever appear here,
/// so nothing sensitive sits in the shared container.
struct WidgetNote: Codable, Hashable {
    /// Display title.
    var title: String
    /// Library-relative path, used to deep-link back into the app.
    var path: String
    /// Whether the note is pinned.
    var pinned: Bool
    /// Last update time.
    var updated: Date
}

/// WidgetSnapshot is everything the widgets know: a handful of notes and a count.
struct WidgetSnapshot: Codable, Hashable {
    /// Pinned notes first, then most recently updated.
    var notes: [WidgetNote]
    /// How many notes the library holds in plain view.
    var totalCount: Int
}

/// WidgetSnapshotStore passes the snapshot between the app and its widgets through the
/// app group container.
enum WidgetSnapshotStore {
    /// Snapshot file inside the group container.
    private static func fileURL() -> URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: ShareInbox.groupIdentifier
        )?.appendingPathComponent("widget-snapshot.json")
    }

    /// Writes the snapshot; returns true when the file actually changed.
    @discardableResult
    static func write(_ snapshot: WidgetSnapshot) -> Bool {
        guard let url = fileURL(),
            let encoder = try? JSONEncoder.sortedEncoder().encode(snapshot)
        else { return false }
        if let existing = try? Data(contentsOf: url), existing == encoder { return false }
        try? encoder.write(to: url, options: .atomic)
        return true
    }

    /// Reads the snapshot, empty when none has been written yet.
    static func read() -> WidgetSnapshot {
        guard let url = fileURL(), let data = try? Data(contentsOf: url),
            let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
        else { return WidgetSnapshot(notes: [], totalCount: 0) }
        return snapshot
    }
}

extension JSONEncoder {
    /// An encoder with stable key order, so unchanged snapshots compare byte-equal.
    static func sortedEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
