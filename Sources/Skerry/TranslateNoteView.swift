import SkerryKit
import SwiftUI

#if canImport(Translation)
    import Translation
#endif

#if canImport(Translation)

    /// UnsafeSessionBox carries the translation session across an await without region
    /// analysis objecting; the session stays inside one closure for its whole life.
    @available(iOS 18.0, macOS 15.0, *)
    private struct UnsafeSessionBox: @unchecked Sendable {
        /// The boxed session.
        let session: TranslationSession
    }

    /// TranslateNoteView translates a note with Apple's on-device translation models and
    /// offers the result for appending or replacing. Language models download on demand
    /// through the system; the note text is translated locally.
    @available(iOS 18.0, macOS 15.0, *)
    struct TranslateNoteView: View {
        /// Body being translated.
        let body_: String
        /// Receives the translated text and whether it replaces the original.
        let onApply: (String, Bool) -> Void
        /// Dismisses the sheet.
        @Environment(\.dismiss) private var dismiss
        /// Chosen target language.
        @State private var target = Locale.Language(identifier: "es")
        /// Translation configuration; setting it triggers the task.
        @State private var configuration: TranslationSession.Configuration?
        /// The translated text once ready.
        @State private var translated: String?
        /// Failure message, if any.
        @State private var failure: String?
        /// Whether translation is running.
        @State private var working = false

        /// Languages offered, a practical starter set.
        private static let choices: [(name: String, code: String)] = [
            ("Spanish", "es"), ("French", "fr"), ("German", "de"), ("Italian", "it"),
            ("Portuguese", "pt"), ("Dutch", "nl"), ("Japanese", "ja"), ("Korean", "ko"),
            ("Chinese", "zh"), ("Arabic", "ar"), ("Hindi", "hi"), ("English", "en"),
        ]

        var body: some View {
            NavigationStack {
                Form {
                    Picker("Translate to", selection: $target) {
                        ForEach(Self.choices, id: \.code) { choice in
                            Text(choice.name).tag(Locale.Language(identifier: choice.code))
                        }
                    }
                    Button(working ? "Translating..." : "Translate") {
                        failure = nil
                        translated = nil
                        working = true
                        configuration = TranslationSession.Configuration(
                            source: nil, target: target
                        )
                    }
                    .disabled(working)
                    if let failure {
                        Text(failure).font(.footnote).foregroundStyle(.secondary)
                    }
                    if let translated {
                        Section("Translation") {
                            Text(translated)
                                .font(.callout)
                                .textSelection(.enabled)
                            Button("Append to Note") {
                                onApply(translated, false)
                                dismiss()
                            }
                            Button("Replace Note Body", role: .destructive) {
                                onApply(translated, true)
                                dismiss()
                            }
                        }
                    }
                }
                .navigationTitle("Translate")
                #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar { Button("Done") { dismiss() } }
                .translationTask(configuration) { session in
                    // The session is handed to this closure to use in place; the box works
                    // around strict-concurrency region analysis rejecting the API's own
                    // intended call shape. The session never leaves this closure.
                    let boxed = UnsafeSessionBox(session: session)
                    let text = body_
                    let result: Result<String, Error>
                    do {
                        result = .success(try await boxed.session.translate(text).targetText)
                    } catch {
                        result = .failure(error)
                    }
                    let outcome = result
                    await MainActor.run {
                        switch outcome {
                        case .success(let text):
                            translated = text
                        case .failure(let error):
                            failure = "Could not translate: \(error.localizedDescription)"
                        }
                        working = false
                    }
                }
            }
            #if os(macOS)
                .frame(minWidth: 420, minHeight: 380)
            #endif
        }
    }

#endif
