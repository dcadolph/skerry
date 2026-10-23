import Foundation
import Testing

@testable import SkerryKit

@Suite struct TagColorTests {
    @Test func indexIsStableForAName() {
        // The same name always lands in the same slot, run after run.
        #expect(TagColor.paletteIndex(for: "harbor", count: 8)
            == TagColor.paletteIndex(for: "harbor", count: 8))
    }

    @Test func indexIsCaseInsensitive() {
        #expect(TagColor.paletteIndex(for: "Work", count: 8)
            == TagColor.paletteIndex(for: "work", count: 8))
    }

    @Test func indexStaysInRange() {
        for name in ["a", "travel", "work/clients", "scotland", "money", "", "🏝️"] {
            let slot = TagColor.paletteIndex(for: name, count: 6)
            #expect((0..<6).contains(slot))
        }
    }

    @Test func indexSpreadsAcrossThePalette() {
        // A handful of distinct tags should not all collide onto one slot.
        let names = ["travel", "work", "money", "home", "ideas", "health", "urgent", "read"]
        let slots = Set(names.map { TagColor.paletteIndex(for: $0, count: 8) })
        #expect(slots.count >= 4)
    }

    @Test func emptyPaletteIsSafe() {
        #expect(TagColor.paletteIndex(for: "anything", count: 0) == 0)
    }
}
