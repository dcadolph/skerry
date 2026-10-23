import Foundation

/// SharedCapture is one item sent into Skerry from the share extension, parked in the app
/// group inbox until the app imports it into the library.
struct SharedCapture: Codable {
    /// Suggested title, usually the shared page or content name.
    var title: String
    /// Captured text, if any.
    var text: String
    /// Captured link, if any.
    var url: String
    /// Captured images as PNG or JPEG bytes.
    var images: [Data]
    /// When the capture happened, for stable import order.
    var createdAt: Date
}

/// ShareInbox reads and writes captures in the app group container, the handoff point
/// between the share extension and the app.
enum ShareInbox {
    /// App group shared by the app and its extensions. iOS requires the `group.` prefix;
    /// macOS uses the team-prefixed form that works without a provisioning profile.
    #if os(macOS)
        static let groupIdentifier = "U7L4P2YHWJ.com.dcadolph.skerry"
    #else
        static let groupIdentifier = "group.com.dcadolph.skerry"
    #endif

    /// Inbox folder inside the group container, created on demand; nil when the group
    /// container is unavailable.
    static func inboxURL() -> URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: groupIdentifier
        ) else { return nil }
        let inbox = container.appendingPathComponent("Inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        return inbox
    }

    /// Writes one capture into the inbox.
    static func deposit(_ capture: SharedCapture) {
        guard let inbox = inboxURL(), let data = try? JSONEncoder().encode(capture) else { return }
        let file = inbox.appendingPathComponent(UUID().uuidString + ".json")
        try? data.write(to: file, options: .atomic)
    }

    /// Reads and removes every parked capture, oldest first.
    static func drain() -> [SharedCapture] {
        guard let inbox = inboxURL(),
            let files = try? FileManager.default.contentsOfDirectory(
                at: inbox, includingPropertiesForKeys: nil
            )
        else { return [] }
        var captures: [SharedCapture] = []
        for file in files where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file),
                let capture = try? JSONDecoder().decode(SharedCapture.self, from: data) {
                captures.append(capture)
            }
            try? FileManager.default.removeItem(at: file)
        }
        return captures.sorted { $0.createdAt < $1.createdAt }
    }
}
