import SkerryKit
import SwiftUI

/// TrashListView shows recently deleted notes with recover and delete-forever actions.
struct TrashListView: View {
    /// Shared library state.
    @Bindable var model: LibraryModel

    var body: some View {
        List {
            if !model.trashedNotes.isEmpty {
                Section {
                    ForEach(model.trashedNotes, id: \.id) { trashed in
                        row(for: trashed)
                    }
                } header: {
                    Text("Deleted notes are removed automatically after 30 days.")
                        .textCase(nil)
                }
            }
        }
        .overlay {
            if model.trashedNotes.isEmpty {
                SkellyEmptyState(
                    title: "Trash Is Empty",
                    message: "Notes you delete rest here for 30 days before the tide reclaims them from the skerry."
                )
            }
        }
        .toolbar {
            ToolbarItem {
                Button("Empty Trash", systemImage: "trash.slash") { model.emptyTrash() }
                    .disabled(model.trashedNotes.isEmpty)
            }
        }
        .navigationTitle("Recently Deleted")
    }

    /// One trashed note row with its title, deletion date, and actions.
    private func row(for trashed: TrashedNote) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(trashed.note.displayTitle ?? stem(trashed.originalPath))
                .font(.headline)
                .lineLimit(1)
            Text("Deleted \(trashed.deletedAt, format: .relative(presentation: .named))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                model.recoverNote(id: trashed.id)
            } label: {
                Label("Recover", systemImage: "arrow.uturn.backward")
            }
            .tint(.green)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                model.purgeNote(id: trashed.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .contextMenu {
            Button("Recover", systemImage: "arrow.uturn.backward") {
                model.recoverNote(id: trashed.id)
            }
            Button("Delete Forever", systemImage: "trash", role: .destructive) {
                model.purgeNote(id: trashed.id)
            }
        }
    }

    /// File name of a path without folders or extension.
    private func stem(_ path: String) -> String {
        let name = String(path.split(separator: "/").last ?? "")
        return name.hasSuffix(".md") ? String(name.dropLast(3)) : name
    }
}
