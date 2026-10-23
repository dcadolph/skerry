import SkerryKit
import SwiftUI

/// PaletteItem is one row the command palette can offer: a note to open or an action.
struct PaletteItem: Identifiable {
    /// Stable identity for list rendering.
    let id: String
    /// Row title shown prominently.
    let title: String
    /// Secondary detail, the note path or action hint.
    let detail: String
    /// SF Symbol for the row.
    let symbol: String
    /// What to do when the row is chosen.
    let run: () -> Void
}

/// CommandPalette is the Cmd-K overlay: fuzzy search over notes plus quick actions.
struct CommandPalette: View {
    /// Shared library state.
    @Bindable var model: LibraryModel
    /// Live query text.
    @State private var query = ""
    /// Index of the highlighted row.
    @State private var highlighted = 0
    /// Focus anchor for the query field.
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextField("Jump to note or action", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(12)
                .focused($fieldFocused)
                .onSubmit { choose(highlighted) }
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { position, item in
                        Button {
                            choose(position)
                        } label: {
                            HStack {
                                Image(systemName: item.symbol)
                                    .frame(width: 20)
                                    .foregroundStyle(.secondary)
                                Text(item.title).lineLimit(1)
                                Spacer()
                                Text(item.detail)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                position == highlighted ? Color.accentColor.opacity(0.14) : .clear,
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 320)
        }
        #if os(macOS)
            .frame(width: 560)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 24, y: 8)
        #else
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 8)
        #endif
        .onAppear { fieldFocused = true }
        .onChange(of: query) { highlighted = 0 }
        #if os(macOS)
            .onMoveCommand { direction in
                switch direction {
                case .down: highlighted = min(highlighted + 1, max(items.count - 1, 0))
                case .up: highlighted = max(highlighted - 1, 0)
                default: break
                }
            }
            .onExitCommand { model.paletteVisible = false }
        #endif
    }

    /// Rows for the current query: actions first on empty query, best note matches after.
    private var items: [PaletteItem] {
        var actions = [
            PaletteItem(
                id: "action.new-note", title: "New Note", detail: "create",
                symbol: "square.and.pencil", run: { model.createNote() }
            ),
            PaletteItem(
                id: "action.photo-note", title: "Photo to Note", detail: "scan text from an image",
                symbol: "text.viewfinder", run: { model.scanRequested = true }
            ),
            PaletteItem(
                id: "action.audio-memo", title: "Audio Memo",
                detail: "record and transcribe on device",
                symbol: "mic", run: { model.memoRequested = true }
            ),
            PaletteItem(
                id: "action.daily-note", title: "Today's Note", detail: "open today's journal",
                symbol: "calendar", run: { model.openDailyNote() }
            ),
        ]
        if model.syncMode != .off {
            actions.append(
                PaletteItem(
                    id: "action.sync", title: "Sync Now", detail: "sync with your storage",
                    symbol: "arrow.triangle.2.circlepath", run: { model.syncNow() }
                )
            )
        }
        for template in model.templates.prefix(5) {
            let name = template.note.displayTitle ?? model.stem(template.path)
            actions.append(
                PaletteItem(
                    id: "template.\(template.path)", title: "New from Template: \(name)",
                    detail: "template", symbol: "doc.on.doc",
                    run: { model.createFromTemplate(template) }
                )
            )
        }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let notes = model.notes
            .compactMap { stored -> (Int, PaletteItem)? in
                let title = stored.note.displayTitle ?? model.stem(stored.path)
                let score = fuzzyScore(needle: trimmed, haystack: title)
                    ?? fuzzyScore(needle: trimmed, haystack: stored.path).map { $0 - 50 }
                guard let score else { return nil }
                return (
                    score,
                    PaletteItem(
                        id: "note.\(stored.path)", title: title, detail: stored.path,
                        symbol: "note.text", run: { model.open(stored.path) }
                    )
                )
            }
            .sorted { $0.0 > $1.0 }
            .prefix(12)
            .map(\.1)
        let matchingActions = trimmed.isEmpty
            ? actions
            : actions.filter { fuzzyScore(needle: trimmed, haystack: $0.title) != nil }
        return matchingActions + notes
    }

    /// Runs a row and closes the palette.
    private func choose(_ position: Int) {
        guard items.indices.contains(position) else { return }
        items[position].run()
        model.paletteVisible = false
        query = ""
    }
}

/// Scores a case-insensitive fuzzy match; nil means no match, higher is better.
/// Prefix beats word boundary beats substring beats scattered subsequence.
func fuzzyScore(needle: String, haystack: String) -> Int? {
    if needle.isEmpty { return 0 }
    let needleChars = Array(needle.lowercased())
    let haystackChars = Array(haystack.lowercased())
    if haystackChars.count >= needleChars.count {
        if Array(haystackChars.prefix(needleChars.count)) == needleChars { return 1000 }
        for start in haystackChars.indices.dropFirst() {
            guard haystackChars[start - 1] == " " else { continue }
            if start + needleChars.count <= haystackChars.count,
                Array(haystackChars[start..<(start + needleChars.count)]) == needleChars {
                return 500
            }
        }
    }
    var position = 0
    var gaps = 0
    var lastHit = -1
    for (offset, char) in haystackChars.enumerated() {
        guard position < needleChars.count, char == needleChars[position] else { continue }
        if lastHit >= 0 { gaps += offset - lastHit - 1 }
        lastHit = offset
        position += 1
    }
    guard position == needleChars.count else { return nil }
    return gaps == 0 ? 250 : max(100 - gaps, 1)
}
