import SwiftUI
import WatchConnectivity

/// WatchModel talks to the phone: dictated captures go out through the queued transfer,
/// which survives the watch app closing, and note titles come back for the list.
@MainActor
@Observable
final class WatchModel: NSObject, WCSessionDelegate {
    /// The one model the watch app uses.
    static let shared = WatchModel()

    /// Note titles last received from the phone.
    var titles: [String] = []
    /// Flips on briefly after a capture is queued, for a moment of confirmation.
    var captured = false

    /// Activates the session and seeds titles from the last received context.
    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
        titles = (WCSession.default.receivedApplicationContext["titles"] as? [String]) ?? []
    }

    /// Queues a dictated capture for the phone.
    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        WCSession.default.transferUserInfo(["capture": trimmed])
        captured = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            captured = false
        }
    }

    nonisolated func session(
        _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {}

    nonisolated func session(
        _ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        let received = (applicationContext["titles"] as? [String]) ?? []
        Task { @MainActor in
            self.titles = received
        }
    }
}

/// SkerryWatchApp is the watch entry point: one screen, capture first.
@main
struct SkerryWatchApp: App {
    /// Shared connectivity model.
    @State private var model = WatchModel.shared

    var body: some Scene {
        WindowGroup {
            WatchHomeView(model: model)
                .onAppear { model.activate() }
        }
    }
}

/// WatchHomeView is the whole watch app: a dictation capture button and recent titles.
struct WatchHomeView: View {
    /// Shared connectivity model.
    @Bindable var model: WatchModel

    var body: some View {
        NavigationStack {
            List {
                TextFieldLink(prompt: Text("New note")) {
                    Label(
                        model.captured ? "Captured" : "Capture Note",
                        systemImage: model.captured ? "checkmark.circle.fill" : "plus.circle.fill"
                    )
                    .foregroundStyle(model.captured ? .green : .primary)
                } onSubmit: { text in
                    model.send(text)
                }
                if !model.titles.isEmpty {
                    Section("Recent") {
                        ForEach(model.titles.prefix(8), id: \.self) { title in
                            Label(title.isEmpty ? "Untitled" : title, systemImage: "note.text")
                                .lineLimit(1)
                        }
                    }
                }
            }
            .navigationTitle("Skerry")
        }
    }
}
