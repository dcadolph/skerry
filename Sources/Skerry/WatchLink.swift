#if os(iOS)

    import Foundation
    import WatchConnectivity

    /// WatchLink relays between the watch and the phone: captures dictated on the wrist
    /// land in the share inbox and become notes, and note titles flow back to the wrist.
    /// The class holds no state, so sharing one instance across threads is safe.
    final class WatchLink: NSObject, WCSessionDelegate {
        /// The one link the app activates at launch.
        nonisolated(unsafe) static let shared = WatchLink()

        /// Starts the session when the device supports a paired watch.
        func activate() {
            guard WCSession.isSupported() else { return }
            let session = WCSession.default
            session.delegate = self
            session.activate()
        }

        /// Publishes note titles to the watch, replacing the previous set.
        func publish(titles: [String]) {
            guard WCSession.isSupported() else { return }
            let session = WCSession.default
            guard session.activationState == .activated, session.isPaired,
                session.isWatchAppInstalled
            else { return }
            try? session.updateApplicationContext(["titles": titles])
        }

        func session(
            _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
            error: Error?
        ) {}

        func sessionDidBecomeInactive(_ session: WCSession) {}

        func sessionDidDeactivate(_ session: WCSession) {
            session.activate()
        }

        /// Receives a queued capture from the watch; delivery survives both apps closing.
        func session(
            _ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]
        ) {
            deposit(userInfo)
        }

        /// Receives a live capture while both apps are frontmost.
        func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
            deposit(message)
        }

        /// Parks a capture in the shared inbox and imports it when the library is open.
        private func deposit(_ payload: [String: Any]) {
            guard let text = payload["capture"] as? String,
                !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return }
            ShareInbox.deposit(
                SharedCapture(title: "", text: text, url: "", images: [], createdAt: Date())
            )
            Task { @MainActor in
                LibraryModel.shared.drainShareInbox()
            }
        }
    }

#endif
