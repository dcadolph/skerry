import SwiftUI
import WidgetKit

/// SnapshotEntry is one timeline entry: the snapshot the app last published.
struct SnapshotEntry: TimelineEntry {
    /// Entry timestamp.
    let date: Date
    /// The published snapshot.
    let snapshot: WidgetSnapshot
}

/// SnapshotProvider serves the group-container snapshot; the app reloads the timeline
/// whenever the snapshot changes, so the policy never fires on its own.
struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(
            date: Date(),
            snapshot: WidgetSnapshot(
                notes: [
                    WidgetNote(title: "Harbor plan", path: "a", pinned: true, updated: Date()),
                    WidgetNote(title: "Reading list", path: "b", pinned: false, updated: Date()),
                ],
                totalCount: 12
            )
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(SnapshotEntry(date: Date(), snapshot: WidgetSnapshotStore.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let entry = SnapshotEntry(date: Date(), snapshot: WidgetSnapshotStore.read())
        completion(Timeline(entries: [entry], policy: .never))
    }
}

/// QuickCaptureWidget is the one-tap new-note button, on the home and lock screens.
struct QuickCaptureWidget: Widget {
    /// Families this widget supports; the accessory ones are lock screen, iOS only.
    private var families: [WidgetFamily] {
        #if os(iOS)
            [.systemSmall, .accessoryCircular]
        #else
            [.systemSmall]
        #endif
    }

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SkerryQuickCapture", provider: SnapshotProvider()) { entry in
            QuickCaptureView(count: entry.snapshot.totalCount)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("New Note")
        .description("Start a new note with one tap.")
        .supportedFamilies(families)
    }
}

/// QuickCaptureView renders the new-note button face for each family.
struct QuickCaptureView: View {
    /// Total note count shown under the button.
    let count: Int
    /// Widget size being rendered.
    @Environment(\.widgetFamily) private var family

    /// Whether this render pass is a lock screen accessory.
    private var isAccessory: Bool {
        #if os(iOS)
            family == .accessoryCircular
        #else
            false
        #endif
    }

    var body: some View {
        Group {
            if isAccessory {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 22, weight: .semibold))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.tint)
                    Spacer()
                    Text("New Note")
                        .font(.headline)
                    Text(count == 1 ? "1 note" : "\(count) notes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
        .widgetURL(URL(string: "skerry://new"))
    }
}

/// RecentNotesWidget lists pinned and recent notes, each a deep link into the app.
struct RecentNotesWidget: Widget {
    /// Families this widget supports; the rectangular accessory is lock screen, iOS only.
    private var families: [WidgetFamily] {
        #if os(iOS)
            [.systemMedium, .systemLarge, .accessoryRectangular]
        #else
            [.systemMedium, .systemLarge]
        #endif
    }

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SkerryRecentNotes", provider: SnapshotProvider()) { entry in
            RecentNotesView(snapshot: entry.snapshot)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Recent Notes")
        .description("Your pinned and latest notes, one tap away.")
        .supportedFamilies(families)
    }
}

/// RecentNotesView renders the note list face.
struct RecentNotesView: View {
    /// Snapshot being shown.
    let snapshot: WidgetSnapshot
    /// Widget size, which decides how many rows fit.
    @Environment(\.widgetFamily) private var family

    /// Whether this render pass is a lock screen accessory.
    private var isAccessory: Bool {
        #if os(iOS)
            family == .accessoryRectangular
        #else
            false
        #endif
    }

    var body: some View {
        if isAccessory {
            accessoryBody
        } else {
            standardBody
        }
    }

    /// Compact lock screen face: the newest note plus a count.
    private var accessoryBody: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("Skerry", systemImage: "note.text")
                .font(.caption2.bold())
            if let first = snapshot.notes.first {
                Text(first.title.isEmpty ? "Untitled" : first.title)
                    .font(.caption)
                    .lineLimit(1)
            }
            Text(snapshot.totalCount == 1 ? "1 note" : "\(snapshot.totalCount) notes")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(
            snapshot.notes.first.map(openURL(for:)) ?? URL(string: "skerry://new")!
        )
    }

    /// Full home screen face with tappable rows.
    private var standardBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Skerry")
                    .font(.headline)
                Spacer()
                Link(destination: URL(string: "skerry://new")!) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.tint)
                }
            }
            if rows.isEmpty {
                Spacer()
                Text("No notes yet. Tap to start one.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ForEach(rows, id: \.path) { note in
                    Link(destination: openURL(for: note)) {
                        HStack(spacing: 6) {
                            Image(systemName: note.pinned ? "pin.fill" : "note.text")
                                .font(.caption)
                                .foregroundStyle(.tint)
                            Text(note.title.isEmpty ? "Untitled" : note.title)
                                .font(.callout)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// Rows that fit the current family.
    private var rows: [WidgetNote] {
        Array(snapshot.notes.prefix(family == .systemLarge ? 7 : 3))
    }

    /// Deep link that opens one note in the app.
    private func openURL(for note: WidgetNote) -> URL {
        var components = URLComponents()
        components.scheme = "skerry"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "path", value: note.path)]
        return components.url ?? URL(string: "skerry://new")!
    }
}

/// SkerryWidgetBundle registers every widget.
@main
struct SkerryWidgetBundle: WidgetBundle {
    var body: some Widget {
        QuickCaptureWidget()
        RecentNotesWidget()
    }
}
