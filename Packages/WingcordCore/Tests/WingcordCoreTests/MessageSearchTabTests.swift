import Testing
@testable import WingcordCore

/// The search tabs' rules — Discord's `768570` (`su`, `B7`) and the spread
/// order of `956467`.
@Suite("Search tabs' questions")
struct MessageSearchTabTests {

    @Test("Each tab adds its own has: nothing, image and video, link, file")
    func tabFilters() {
        var query = MessageSearchQuery(scope: .channel(ChannelID(rawValue: 1)))
        query.tab = .messages
        #expect(query.tabHas.isEmpty)
        query.tab = .media
        #expect(query.tabHas == [.image, .video])
        query.tab = .links
        #expect(query.tabHas == [.link])
        query.tab = .files
        #expect(query.tabHas == [.file])
    }

    @Test("The question's own has wins over the tab's")
    func ownHasWins() {
        var query = MessageSearchQuery(scope: .channel(ChannelID(rawValue: 1)))
        query.has = [.poll, .embed]
        query.tab = .media
        #expect(query.tabHas == [.embed, .poll])
    }

    @Test("A tab is not a filter: no badge counts it, Clear keeps it")
    func notAFilter() {
        var query = MessageSearchQuery(scope: .channel(ChannelID(rawValue: 1)))
        query.content = "hello"
        query.tab = .links
        query.authorIDs = [UserID(rawValue: 2)]
        #expect(query.activeFilterCount == 1)
        let cleared = query.clearingFilters()
        #expect(cleared.tab == .links)
        #expect(cleared.authorIDs.isEmpty)
        #expect(cleared.onPage(3).tab == .links)
    }
}
