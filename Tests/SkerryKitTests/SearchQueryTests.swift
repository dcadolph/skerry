import Foundation
import Testing

@testable import SkerryKit

@Suite struct SearchQueryTests {
    @Test func operatorsAndTermsSplit() {
        let query = SearchQuery.parse("@todo harbor plan @pinned")
        #expect(query.filters == [.todo, .pinned])
        #expect(query.text == "harbor plan")
    }

    @Test func tagFiltersParseBothForms() {
        #expect(SearchQuery.parse("#work").filters == [.tag("work")])
        #expect(SearchQuery.parse("@tag:work/clients").filters == [.tag("work/clients")])
        #expect(SearchQuery.parse("# alone").filters.isEmpty)
    }

    @Test func plainQueriesHaveNoFilters() {
        let query = SearchQuery.parse("just some words")
        #expect(query.filters.isEmpty)
        #expect(query.text == "just some words")
    }

    @Test func allOperatorSpellingsParse() {
        let query = SearchQuery.parse("@tasks @images @files @starred @encrypted @locked @done")
        #expect(query.filters == [.todo, .images, .files, .starred, .encrypted, .locked, .done])
        #expect(query.text.isEmpty)
    }

    @Test func noteQueriesSeeTasks() {
        #expect(NoteQueries.hasOpenTasks("- [ ] buy rope\n"))
        #expect(!NoteQueries.hasOpenTasks("- [x] done thing\n"))
        #expect(NoteQueries.hasDoneTasks("- [x] done thing\n"))
        #expect(!NoteQueries.hasOpenTasks("plain words"))
        #expect(NoteQueries.hasOpenTasks("# T\n\n  - [ ] nested\n"))
    }

    @Test func noteQueriesSeeAttachments() {
        #expect(NoteQueries.hasImages("look ![](../assets/pic.png)"))
        #expect(!NoteQueries.hasImages("no pictures here"))
        #expect(NoteQueries.hasFileLinks("the [report](../assets/report.pdf)"))
        #expect(!NoteQueries.hasFileLinks("a web [link](https://example.com)"))
        #expect(!NoteQueries.hasFileLinks("an ![image](../assets/pic.png) only"))
    }
}
