import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// A page of channel history, decoded the way `messages(in:)` decodes it.
///
/// **One message this client cannot read must not take the page with it**,
/// and it must still count: the store decides that a window reached either
/// end of a channel from how many messages Discord sent, so a page one short
/// by what was *read* would end the paging there.
@Suite("History pages")
struct HistoryPageDecodeTests {

    /// Newest first, as Discord sends a page. The middle one has lost its
    /// `channel_id`, which a message cannot be read without.
    private let page = """
    [{"id":"3","channel_id":"9","type":0,"content":"c","author":{"id":"5","username":"alex"}},
     {"id":"2","type":0,"content":"b","author":{"id":"5","username":"alex"}},
     {"id":"1","channel_id":"9","type":0,"content":"a","author":{"id":"5","username":"alex"}}]
    """

    @Test("An unreadable message is left out and still counted")
    func lossy() throws {
        let list = try JSONDecoder().decode(LossyList<MessageDTO>.self, from: Data(page.utf8))
        #expect(list.elements.count == 2)
        #expect(list.dropped == 1)
        #expect(list.wireCount == 3)

        let decoded = DiscordREST.page(from: list.elements, reversed: true, wireCount: list.wireCount)
        #expect(decoded.messages.map(\.id.rawValue) == [1, 3])
        #expect(decoded.wireCount == 3)
    }

    @Test("A page with nothing unreadable counts itself")
    func whole() {
        let decoded = DiscordREST.page(from: [], reversed: true)
        #expect(decoded.wireCount == 0)
    }
}
