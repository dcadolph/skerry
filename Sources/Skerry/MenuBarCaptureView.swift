#if os(macOS)

    import SwiftUI

    /// MenuBarCaptureView is the menu bar quick-capture window: type a thought, save it as
    /// a note without bringing the app forward.
    struct MenuBarCaptureView: View {
        /// Shared library state.
        @Bindable var model: LibraryModel
        /// Text being captured.
        @State private var draft = ""
        /// Flips briefly after a save for a moment of confirmation.
        @State private var saved = false

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                Text("Quick Capture")
                    .font(.headline)
                TextEditor(text: $draft)
                    .font(.body)
                    .frame(width: 300, height: 120)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                HStack {
                    Button(saved ? "Saved" : "Save Note") {
                        save()
                    }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Spacer()
                    Button("Open Skerry") {
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
            }
            .padding(14)
            .onAppear {
                // The menu bar item can outlive the window; make sure a library is open so
                // a capture never lands nowhere.
                model.reopenLastLibrary()
            }
        }

        /// Saves the draft as a note and clears the field.
        private func save() {
            let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            model.reopenLastLibrary()
            guard model.store != nil else { return }
            model.createNoteFromCapture(title: "", text: text)
            draft = ""
            saved = true
            Task {
                try? await Task.sleep(for: .seconds(2))
                saved = false
            }
        }
    }

#endif
