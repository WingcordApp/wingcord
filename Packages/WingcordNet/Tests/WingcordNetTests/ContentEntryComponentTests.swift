import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// A reply to somebody's activity arrives with Discord's component 16, whose
/// `content_inventory_entry` is the activity (docs/ACTIVITY-CARDS.md
/// decision 11).
@Suite("Activity replies on the wire")
struct ContentEntryComponentTests {

    @Test("Component 16 carries the activity the reply is about")
    func componentCarriesTheEntry() throws {
        let json = """
        {"id":"10","channel_id":"20","content":"nice","type":0,
         "author":{"id":"30","username":"someone"},
         "components":[{"type":16,"content_inventory_entry":{
            "id":"1400000000000000777","author_id":"40","content_type":6,
            "traits":[{"type":4,"range":1},{"type":12,"count":14}],
            "extra":{"type":"top_artist_extra","artist":{"name":"An Artist","external_id":"9"},
                     "media":{"title":"A Track","parent_title":"An Album","provider":1}}}}]}
        """
        let message = try JSONDecoder().decode(MessageDTO.self, from: Data(json.utf8)).domain
        let entry = try #require(message.contentEntry)
        #expect(entry.authorID == UserID(rawValue: 40))
        #expect(entry.weeklyCount == 14)
        #expect(entry.details.album == "An Album")
        // Not a V2 message: the component doesn't turn the body into a tree.
        #expect(message.payload?.displayComponents.isEmpty == true)
    }

    @Test("A message without it carries none")
    func plainMessage() throws {
        let json = #"{"id":"10","channel_id":"20","content":"hi","type":0,"author":{"id":"30","username":"someone"}}"#
        let message = try JSONDecoder().decode(MessageDTO.self, from: Data(json.utf8)).domain
        #expect(message.contentEntry == nil)
    }
}
