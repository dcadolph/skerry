import SkerryKit
import SwiftUI

/// ConflictReviewView lists sync conflict copies beside their originals and
/// resolves each by keeping one side or both.
struct ConflictReviewView: View {
    /// Shared library state.
    @Bindable var model: LibraryModel
    /// Dismisses the sheet.
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if model.conflictPairs.isEmpty {
                    ContentUnavailableView(
                        "No Conflicts",
                        systemImage: "checkmark.circle",
                        description: Text("Your notes agree across devices.")
                    )
                } else {
                    List(model.conflictPairs) { pair in
                        ConflictRow(model: model, pair: pair)
                    }
                }
            }
            .navigationTitle("Sync Conflicts")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
            .frame(minWidth: 620, minHeight: 420)
        #endif
    }
}

/// ConflictRow shows one conflict: both versions side by side with resolution buttons.
private struct ConflictRow: View {
    /// Shared library state.
    var model: LibraryModel
    /// The conflict under review.
    let pair: ConflictPair

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            if let original = pair.original {
                HStack(alignment: .top, spacing: 12) {
                    preview("On This Device", of: original)
                    preview("From Sync", of: pair.copy)
                }
                HStack {
                    Button("Keep Mine") { model.resolveConflictKeepingMine(pair) }
                    Button("Keep Theirs") { model.resolveConflictKeepingTheirs(pair) }
                    Button("Keep Both") { model.resolveConflictKeepingBoth(pair) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                preview("From Sync", of: pair.copy)
                Text("The note this copy forked from was deleted on this device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Keep Copy") { model.resolveConflictKeepingTheirs(pair) }
                    Button("Delete Copy") { model.resolveConflictKeepingMine(pair) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 6)
    }

    /// Best available display title for the conflicted note.
    private var title: String {
        pair.original?.note.displayTitle
            ?? pair.copy.note.displayTitle
            ?? model.stem(pair.original?.path ?? pair.copy.path)
    }

    /// A labeled excerpt of one side of the conflict, with its last-edit time.
    private func preview(_ label: String, of stored: StoredNote) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.caption.weight(.semibold))
                Spacer()
                if stored.updated > .distantPast {
                    Text(stored.updated, format: .dateTime.day().month().hour().minute())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Text(excerpt(of: stored))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(8)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    /// The first stretch of a note's body, or a placeholder while it is locked.
    private func excerpt(of stored: StoredNote) -> String {
        guard model.isReadable(stored) else { return "Locked" }
        let body = stored.note.body.trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? "Empty note" : String(body.prefix(400))
    }
}
