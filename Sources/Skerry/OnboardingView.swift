import SwiftUI

/// OnboardingView is the first-run tour: what Skerry is, where notes live, and how
/// to lock them. Shown once on first launch and revisitable from settings.
struct OnboardingView: View {
    /// Called when the tour ends; true asks for the security settings next.
    let onFinish: (Bool) -> Void
    /// Index of the visible page.
    @State private var page = 0

    /// One screen of the tour.
    private struct Page {
        /// SF Symbol shown large above the title.
        let icon: String
        /// Page heading.
        let title: String
        /// Supporting message.
        let message: String
    }

    /// The tour in order: identity, files, security, sync.
    private static let pages = [
        Page(
            icon: "bird",
            title: "Welcome to Skerry",
            message: "A notes app that keeps your writing in plain Markdown files, in a "
                + "folder you choose. No accounts, no servers, no telemetry."
        ),
        Page(
            icon: "folder",
            title: "Files, Not a Database",
            message: "Every note is a file you can open in any editor, today or in twenty "
                + "years. Point Skerry at any folder and it becomes your library."
        ),
        Page(
            icon: "lock.shield",
            title: "Lock What Matters",
            message: "Encrypt single notes or the whole library behind a passphrase. "
                + "Write down the recovery code when you set one; there is no reset, "
                + "because a reset for you would be a back door for everyone else."
        ),
        Page(
            icon: "arrow.triangle.2.circlepath",
            title: "Sync on Your Terms",
            message: "Keep devices in step through your own storage: a shared folder, "
                + "WebDAV, or S3. Notes are sealed before they leave the device. Head to "
                + "Settings to connect one when you are ready."
        ),
    ]

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: Self.pages[page].icon)
                .font(.system(size: 64))
                .foregroundStyle(.tint)
                .frame(height: 80)
            Text(Self.pages[page].title)
                .font(.largeTitle.weight(.bold))
                .multilineTextAlignment(.center)
            Text(Self.pages[page].message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            HStack(spacing: 8) {
                ForEach(Self.pages.indices, id: \.self) { index in
                    Circle()
                        .fill(index == page ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }
            controls
        }
        .padding(28)
        .animation(.snappy, value: page)
        #if os(macOS)
            .frame(minWidth: 520, minHeight: 480)
        #endif
    }

    /// Continue and skip until the last page, then the two ways to begin.
    @ViewBuilder
    private var controls: some View {
        if page < Self.pages.count - 1 {
            VStack(spacing: 10) {
                Button {
                    page += 1
                } label: {
                    Text("Continue")
                        .frame(maxWidth: 320)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Button("Skip") { onFinish(false) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        } else {
            VStack(spacing: 10) {
                Button {
                    onFinish(true)
                } label: {
                    Text("Set Up Encryption")
                        .frame(maxWidth: 320)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Button("Start Writing") { onFinish(false) }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
            }
        }
    }
}
