import SkerryKit
import SwiftUI

/// VersionHistoryView lists a note's recorded versions with previews and restore.
struct VersionHistoryView: View {
    /// Shared library state.
    @Bindable var model: LibraryModel
    /// Path of the note whose history is showing.
    let path: String
    /// Dismisses the sheet.
    @Environment(\.dismiss) private var dismiss
    /// Version awaiting restore confirmation; nil when the dialog is closed.
    @State private var confirmRestore: VersionStore.Version?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Version History")
                #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar { Button("Done") { dismiss() } }
        }
        #if os(macOS)
            .frame(minWidth: 480, minHeight: 420)
        #endif
        .confirmationDialog(
            "Restore this version?",
            isPresented: Binding(
                get: { confirmRestore != nil },
                set: { if !$0 { confirmRestore = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Restore", role: .destructive) {
                if let confirmRestore {
                    model.restoreVersion(confirmRestore, for: path)
                }
                confirmRestore = nil
                dismiss()
            }
            Button("Cancel", role: .cancel) { confirmRestore = nil }
        } message: {
            Text("The current state is saved as a version first, so this can be undone.")
        }
    }

    /// The version list, or an empty state before any version exists.
    @ViewBuilder
    private var content: some View {
        let versions = model.versions(for: path)
        if versions.isEmpty {
            ContentUnavailableView(
                "No Versions Yet",
                systemImage: "clock.arrow.circlepath",
                description: Text("Versions are recorded automatically as you edit.")
            )
        } else {
            List(versions) { version in
                DisclosureGroup {
                    preview(for: version)
                    Button("Restore This Version") { confirmRestore = version }
                        .buttonStyle(.borderedProminent)
                        .padding(.vertical, 4)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(version.date.formatted(date: .abbreviated, time: .shortened))
                        Text(
                            version.date.formatted(
                                .relative(presentation: .named, unitsStyle: .wide)
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// A readable preview of a version's body, or a lock note when the vault is closed.
    @ViewBuilder
    private func preview(for version: VersionStore.Version) -> some View {
        if let body = model.versionPreview(version) {
            ScrollView {
                Text(body.isEmpty ? "Empty note" : String(body.prefix(4000)))
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
            .padding(8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        } else {
            Label("Unlock the vault to preview this version.", systemImage: "lock")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
