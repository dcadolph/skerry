import AppIntents
import Foundation

/// IntentError surfaces a readable failure to Shortcuts and Siri.
enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    /// No library has been opened in the app yet.
    case noLibrary
    /// No note matched the given title.
    case noteNotFound(String)
    /// The note exists but is locked or encrypted and the vault is closed.
    case notWritable(String)
    /// Sync is not configured.
    case syncOff

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noLibrary:
            return "Open Skerry once to set up your library first."
        case .noteNotFound(let title):
            return "No note named \(title) was found."
        case .notWritable(let title):
            return "\(title) is locked or encrypted. Unlock it in Skerry first."
        case .syncOff:
            return "Set up sync in Skerry settings first."
        }
    }
}

/// CreateNoteIntent creates a note from Shortcuts, Siri, or Spotlight.
struct CreateNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Create Note"
    static let description = IntentDescription("Creates a new note in your Skerry library.")

    /// Optional note title; the first line of the text fills in when empty.
    @Parameter(title: "Title") var noteTitle: String?
    /// Body text of the note.
    @Parameter(title: "Text") var text: String?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = LibraryModel.shared
        model.reopenLastLibrary()
        guard model.store != nil else { throw IntentError.noLibrary }
        let cleaned = (noteTitle ?? "").trimmingCharacters(in: .whitespaces)
        model.createNoteFromCapture(title: cleaned, text: text ?? "")
        let shown = cleaned.isEmpty ? "a new note" : cleaned
        return .result(dialog: "Created \(shown) in Skerry.")
    }
}

/// AppendToNoteIntent adds text to the end of an existing note.
struct AppendToNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Append to Note"
    static let description = IntentDescription("Adds text to the end of an existing note.")

    /// Title or file name of the target note.
    @Parameter(title: "Note") var noteTitle: String
    /// Text to append.
    @Parameter(title: "Text") var text: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = LibraryModel.shared
        model.reopenLastLibrary()
        guard model.store != nil else { throw IntentError.noLibrary }
        guard let path = model.resolveWikiLink(noteTitle) else {
            throw IntentError.noteNotFound(noteTitle)
        }
        guard let stored = model.notes.first(where: { $0.path == path }),
            model.isReadable(stored)
        else { throw IntentError.notWritable(noteTitle) }
        let body = stored.note.body
        let separator = body.isEmpty || body.hasSuffix("\n") ? "" : "\n"
        model.updateBody(body + separator + text + "\n", for: path)
        return .result(dialog: "Added to \(noteTitle).")
    }
}

/// SearchNotesIntent returns the titles matching a search.
struct SearchNotesIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Notes"
    static let description = IntentDescription("Searches your notes and returns matching titles.")

    /// Search terms.
    @Parameter(title: "Search For") var term: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[String]> {
        let model = LibraryModel.shared
        model.reopenLastLibrary()
        guard let index = model.index else { throw IntentError.noLibrary }
        let hits = (try? index.search(term)) ?? []
        let titles = hits.map { hit in
            hit.title.isEmpty ? model.stem(hit.path) : hit.title
        }
        return .result(value: titles)
    }
}

/// OpenNoteIntent opens a note in the app.
struct OpenNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Note"
    static let description = IntentDescription("Opens a note in Skerry.")
    static let openAppWhenRun = true

    /// Title or file name of the note to open.
    @Parameter(title: "Note") var noteTitle: String

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = LibraryModel.shared
        model.reopenLastLibrary()
        guard model.store != nil else { throw IntentError.noLibrary }
        guard let path = model.resolveWikiLink(noteTitle) else {
            throw IntentError.noteNotFound(noteTitle)
        }
        model.open(path)
        return .result()
    }
}

/// SyncNowIntent runs a sync pass with the configured storage.
struct SyncNowIntent: AppIntent {
    static let title: LocalizedStringResource = "Sync Notes"
    static let description = IntentDescription("Syncs your library with your own storage.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = LibraryModel.shared
        model.reopenLastLibrary()
        guard model.store != nil else { throw IntentError.noLibrary }
        guard model.syncMode != .off else { throw IntentError.syncOff }
        model.syncNow()
        return .result(dialog: "Sync started.")
    }
}

/// SkerryShortcuts surfaces the core intents to Spotlight and Siri with spoken phrases.
struct SkerryShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CreateNoteIntent(),
            phrases: [
                "Create a note in \(.applicationName)",
                "New \(.applicationName) note",
            ],
            shortTitle: "Create Note",
            systemImageName: "square.and.pencil"
        )
        AppShortcut(
            intent: SearchNotesIntent(),
            phrases: ["Search \(.applicationName) notes"],
            shortTitle: "Search Notes",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: SyncNowIntent(),
            phrases: ["Sync \(.applicationName)"],
            shortTitle: "Sync Notes",
            systemImageName: "arrow.triangle.2.circlepath"
        )
    }
}
