import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// Discord's component tree grows without warning, and a decoder that throws on
/// an unknown type throws away the whole message page it arrived in.
@Suite("Component decoding")
struct ComponentDecodeTests {

    private func decode(_ json: String) throws -> [ActionRow] {
        let rows = try JSONDecoder().decode([ComponentDTO].self, from: Data(json.utf8))
        return ComponentDTO.rows(rows)
    }

    @Test("A link button carries its destination")
    func linkButton() throws {
        let rows = try decode("""
        [{"type":1,"components":[
          {"type":2,"style":5,"label":"View release","url":"https://example.test/r"}
        ]}]
        """)
        #expect(rows.count == 1)
        #expect(rows[0].components[0].label == "View release")
        #expect(rows[0].components[0].destination == "https://example.test/r")
        #expect(rows[0].components[0].isActionable)
    }

    /// **A link style with no URL is not a link.** It cannot be pressed and it
    /// cannot say where it goes, so keeping it would be drawing a live control
    /// over nothing.
    @Test("A link button with no URL is dropped")
    func linkWithoutURL() throws {
        let rows = try decode("""
        [{"type":1,"components":[{"type":2,"style":5,"label":"Broken"}]}]
        """)
        #expect(rows.isEmpty)
    }

    /// **This used to assert the opposite**, and it was right to: until the
    /// component interaction was captured, an action button was drawn and dead.
    /// It now carries the `custom_id` a press has to echo. See
    /// `MessageComponentInteractionTests`.
    @Test("An interaction button carries the custom_id a press echoes")
    func actionButton() throws {
        let rows = try decode("""
        [{"type":1,"components":[
          {"type":2,"style":1,"label":"Refresh","custom_id":"refresh"}
        ]}]
        """)
        #expect(rows[0].components[0].label == "Refresh")
        #expect(rows[0].components[0].customID == "refresh")
        #expect(rows[0].components[0].isActionable)
        // A link and an action are exclusive: one opens, the other posts.
        #expect(rows[0].components[0].destination == nil)
    }

    /// The failure this decoder exists to avoid: one unrecognised type must not
    /// cost the message its other controls.
    @Test("An unknown component type is skipped, not thrown on")
    func unknownTypeIsSkipped() throws {
        let rows = try decode("""
        [{"type":1,"components":[
          {"type":99,"label":"From the future"},
          {"type":2,"style":5,"label":"Open","url":"https://example.test/o"}
        ]}]
        """)
        #expect(rows.count == 1)
        #expect(rows[0].components.count == 1)
        #expect(rows[0].components[0].label == "Open")
    }

    @Test("A row with nothing drawable in it is dropped entirely")
    func emptyRowIsDropped() throws {
        let rows = try decode("""
        [{"type":1,"components":[{"type":99}]}]
        """)
        #expect(rows.isEmpty)
    }

    @Test("Every select menu flavour becomes its placeholder")
    func selectMenus() throws {
        for type in [3, 5, 6, 7, 8] {
            let rows = try decode("""
            [{"type":1,"components":[
              {"type":\(type),"custom_id":"pick","placeholder":"Choose a role"}
            ]}]
            """)
            #expect(rows[0].components[0].label == "Choose a role")
            #expect(!rows[0].components[0].isActionable)
        }
    }

    /// A Components V2 container is not an action row, and `isComponentsV2`
    /// already flags the message it arrives on.
    @Test("A non-row top-level component is skipped")
    func componentsV2IsSkipped() throws {
        let rows = try decode("""
        [{"type":17,"components":[{"type":10,"content":"hello"}]}]
        """)
        #expect(rows.isEmpty)
    }
}
