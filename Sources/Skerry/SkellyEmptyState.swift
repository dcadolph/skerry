import SwiftUI

/// SkellyEmptyState is the branded placeholder: Skelly on the rock plus a short message.
struct SkellyEmptyState: View {
    /// Headline under the art.
    let title: String
    /// One supporting sentence.
    let message: String
    /// Optional call-to-action label; the button shows only when this and the action are set.
    var actionTitle: String?
    /// Optional call-to-action handler paired with the label.
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image("Skelly")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 280)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            Text(title)
                .font(.title3.bold())
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
        }
        .padding(24)
        .frame(maxWidth: 380)
    }
}
