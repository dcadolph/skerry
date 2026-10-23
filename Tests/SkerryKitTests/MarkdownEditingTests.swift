import Foundation
import Testing

@testable import SkerryKit

@Suite struct MarkdownEditingTests {
    @Test func bulletListContinues() {
        let text = "# T\n\n- milk"
        let action = MarkdownEditing.newlineAction(text: text, caret: (text as NSString).length)
        #expect(action == .insert("\n- "))
    }

    @Test func asteriskAndPlusMarkersContinue() {
        #expect(MarkdownEditing.newlineAction(text: "* a", caret: 3) == .insert("\n* "))
        #expect(MarkdownEditing.newlineAction(text: "+ a", caret: 3) == .insert("\n+ "))
    }

    @Test func orderedListIncrements() {
        let text = "1. first\n2. second"
        let action = MarkdownEditing.newlineAction(text: text, caret: (text as NSString).length)
        #expect(action == .insert("\n3. "))
    }

    @Test func indentIsPreserved() {
        let text = "  - nested"
        let action = MarkdownEditing.newlineAction(text: text, caret: (text as NSString).length)
        #expect(action == .insert("\n  - "))
    }

    @Test func emptyItemExitsList() {
        let text = "- milk\n- "
        let action = MarkdownEditing.newlineAction(text: text, caret: (text as NSString).length)
        #expect(action == .replaceRange(NSRange(location: 7, length: 2), with: ""))
    }

    @Test func taskListContinuesAsFreshCheckbox() {
        // A checked or unchecked item both continue as a new empty box.
        #expect(MarkdownEditing.newlineAction(text: "- [ ] milk", caret: 10) == .insert("\n- [ ] "))
        #expect(MarkdownEditing.newlineAction(text: "- [x] milk", caret: 10) == .insert("\n- [ ] "))
        #expect(MarkdownEditing.newlineAction(text: "* [X] a", caret: 7) == .insert("\n* [ ] "))
    }

    @Test func taskListPreservesIndent() {
        let text = "  - [ ] nested"
        let action = MarkdownEditing.newlineAction(text: text, caret: (text as NSString).length)
        #expect(action == .insert("\n  - [ ] "))
    }

    @Test func emptyTaskItemExitsList() {
        let text = "- [ ] milk\n- [ ] "
        let action = MarkdownEditing.newlineAction(text: text, caret: (text as NSString).length)
        #expect(action == .replaceRange(NSRange(location: 11, length: 6), with: ""))
    }

    @Test func quoteContinuesAndEmptyQuoteExits() {
        #expect(MarkdownEditing.newlineAction(text: "> words", caret: 7) == .insert("\n> "))
        let exit = MarkdownEditing.newlineAction(text: "> ", caret: 2)
        #expect(exit == .replaceRange(NSRange(location: 0, length: 2), with: ""))
    }

    @Test func plainProseStaysPlain() {
        #expect(MarkdownEditing.newlineAction(text: "just words", caret: 10) == .plain)
        #expect(MarkdownEditing.newlineAction(text: "3.14 is pi", caret: 10) == .plain)
    }

    @Test func toggleTaskFlipsCheckbox() {
        #expect(MarkdownEditing.toggleTask(text: "- [ ] milk", at: 2) == "- [x] milk")
        #expect(MarkdownEditing.toggleTask(text: "- [x] milk", at: 0) == "- [ ] milk")
        #expect(MarkdownEditing.toggleTask(text: "- [X] milk", at: 3) == "- [ ] milk")
    }

    @Test func toggleTaskIgnoresNonTaskLines() {
        #expect(MarkdownEditing.toggleTask(text: "- milk", at: 2) == nil)
        #expect(MarkdownEditing.toggleTask(text: "plain text", at: 4) == nil)
    }

    @Test func toggleTaskIgnoresTapPastTheBox() {
        // Tapping deep in the content, not the marker, should not toggle.
        #expect(MarkdownEditing.toggleTask(text: "- [ ] milk", at: 9) == nil)
    }

    @Test func toggleTaskInMultilineHitsRightLine() {
        let text = "- [ ] one\n- [ ] two"
        #expect(MarkdownEditing.toggleTask(text: text, at: 12) == "- [ ] one\n- [x] two")
    }
}
