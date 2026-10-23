import SwiftUI

/// FormatTip explains one formatting control: its icon, name, and how to use it.
struct FormatTip: Identifiable {
    /// Stable identity for paging.
    let id = UUID()
    /// SF Symbol shown on the page.
    let symbol: String
    /// Control name.
    let title: String
    /// One or two sentences on what it does.
    let detail: String
    /// A small Markdown example the control produces.
    let example: String
}

/// KeyboardHelpView is a swipeable manual: one formatting control per page.
struct KeyboardHelpView: View {
    /// Dismisses the guide.
    @Environment(\.dismiss) private var dismiss

    /// Every control the formatting keyboard and toolbar offer.
    private let tips: [FormatTip] = [
        .init(symbol: "checklist", title: "Checklist", detail: "Starts a task you can tap to check off. Tap the box to toggle it done.", example: "- [ ] Buy milk"),
        .init(symbol: "list.bullet", title: "Bullet List", detail: "Starts a bulleted list. Press return to add the next bullet, or an empty one to stop.", example: "- First\n- Second"),
        .init(symbol: "list.number", title: "Numbered List", detail: "Starts a numbered list that counts up on its own as you press return.", example: "1. First\n2. Second"),
        .init(symbol: "number", title: "Heading", detail: "Turns the line into a heading. More hashes make a smaller heading.", example: "# Big title"),
        .init(symbol: "bold", title: "Bold", detail: "Makes the selected text bold, or drops in an empty pair to type into.", example: "**important**"),
        .init(symbol: "italic", title: "Italic", detail: "Italicizes the selected text.", example: "*subtle*"),
        .init(symbol: "strikethrough", title: "Strikethrough", detail: "Draws a line through text to show it is done or dropped.", example: "~~old plan~~"),
        .init(symbol: "chevron.left.forwardslash.chevron.right", title: "Code", detail: "Formats text as inline code in a monospaced font.", example: "`code`"),
        .init(symbol: "link", title: "Link", detail: "Inserts a link. Type the text in the brackets and the address in the parentheses.", example: "[label](https://…)"),
        .init(symbol: "quote.opening", title: "Quote", detail: "Formats the line as a quotation.", example: "> A quote"),
        .init(symbol: "increase.indent", title: "Indent", detail: "Pushes the line right to nest it under the item above.", example: "  - nested"),
        .init(symbol: "decrease.indent", title: "Outdent", detail: "Pulls the line back to the left, undoing an indent.", example: "- top level"),
        .init(symbol: "minus", title: "Divider", detail: "Drops a horizontal line to separate sections.", example: "---"),
        .init(symbol: "curlybraces.square", title: "Code Block", detail: "Inserts a fenced block for multiple lines of code.", example: "```\ncode\n```"),
        .init(symbol: "tablecells", title: "Table", detail: "Inserts a small table you can fill in.", example: "| A | B |\n| - | - |"),
        .init(symbol: "calendar", title: "Date", detail: "Inserts today's date at the cursor.", example: "Jul 13, 2026"),
        .init(symbol: "clock", title: "Time", detail: "Inserts the current time at the cursor.", example: "11:04 PM"),
        .init(symbol: "arrow.uturn.backward", title: "Undo", detail: "Reverses your last change.", example: ""),
        .init(symbol: "arrow.uturn.forward", title: "Redo", detail: "Reapplies a change you just undid.", example: ""),
        .init(symbol: "delete.left", title: "Delete", detail: "Removes the character before the cursor.", example: ""),
        .init(symbol: "return", title: "Return", detail: "Starts a new line. On a list it continues the list; on an empty item it ends it.", example: ""),
        .init(symbol: "keyboard.badge.ellipsis", title: "Formatting Keyboard", detail: "Swaps the letter keyboard for the formatting grid. Tap it again, or ABC, to return.", example: ""),
        .init(symbol: "character", title: "Letter Keyboard (ABC)", detail: "Returns to the normal typing keyboard from the formatting grid.", example: ""),
    ]

    var body: some View {
        NavigationStack {
            TabView {
                ForEach(tips) { tip in
                    page(for: tip)
                }
            }
            #if os(iOS)
                .tabViewStyle(.page(indexDisplayMode: .always))
            #endif
            .navigationTitle("Formatting Guide")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                Button("Done") { dismiss() }
            }
        }
    }

    /// One manual page for a single control.
    private func page(for tip: FormatTip) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: tip.symbol)
                .font(.system(size: 56))
                .foregroundStyle(.tint)
                .frame(height: 70)
            Text(tip.title)
                .font(.title2.bold())
            Text(tip.detail)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            if !tip.example.isEmpty {
                Text(tip.example)
                    .font(.system(.callout, design: .monospaced))
                    .padding(12)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            }
            Spacer()
            Spacer()
        }
        .padding()
    }
}
