import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// Components V2 — a message whose entire body is the component tree.
@Suite("Components V2")
struct DisplayComponentTests {

    private func tree(_ json: String) throws -> [DisplayComponent] {
        ComponentDTO.display(try JSONDecoder().decode([ComponentDTO].self, from: Data(json.utf8)))
    }

    private func rows(_ json: String) throws -> [ActionRow] {
        ComponentDTO.rows(try JSONDecoder().decode([ComponentDTO].self, from: Data(json.utf8)))
    }

    /// **A V1 payload must not become a tree**, or the same buttons are laid out
    /// twice — once by the flat path and once by the tree.
    @Test("A payload of plain action rows yields no tree")
    func actionRowsAreNotATree() throws {
        let json = """
        [{"type":1,"components":[
          {"type":2,"style":5,"label":"Open","url":"https://example.test/o"}]}]
        """
        #expect(try tree(json).isEmpty)
        #expect(try rows(json).count == 1)
    }

    @Test("A container carries its accent and its children")
    func container() throws {
        let nodes = try tree("""
        [{"type":17,"accent_color":16007990,"components":[
          {"type":10,"content":"## Lumen Club Roadmap"},
          {"type":14,"divider":true,"spacing":1},
          {"type":10,"content":"v0.1.5 — Personalize everything"}]}]
        """)
        #expect(nodes.count == 1)
        guard case .container(let accent, let children) = nodes[0] else {
            Issue.record("expected a container")
            return
        }
        #expect(accent == 16_007_990)
        #expect(children.count == 3)
        guard case .text(let heading) = children[0] else {
            Issue.record("expected text")
            return
        }
        #expect(heading == "## Lumen Club Roadmap")
    }

    /// Zero is a black accent nobody picks; an unset one arrives as null.
    /// Drawing zero as a rule paints a black bar down every card that omitted it.
    @Test("A zero accent is no accent")
    func zeroAccent() throws {
        let nodes = try tree(#"[{"type":17,"accent_color":0,"components":[{"type":10,"content":"x"}]}]"#)
        guard case .container(let accent, _) = nodes[0] else {
            Issue.record("expected a container")
            return
        }
        #expect(accent == nil)
    }

    /// A row inside a container stays inside it, so the buttons draw on the card
    /// rather than being hoisted underneath every one of them.
    @Test("A row inside a container stays in the tree")
    func rowInsideContainer() throws {
        let nodes = try tree("""
        [{"type":17,"components":[
          {"type":10,"content":"hi"},
          {"type":1,"components":[
            {"type":2,"style":5,"label":"Open","url":"https://example.test/o"}]}]}]
        """)
        guard case .container(_, let children) = nodes[0], children.count == 2 else {
            Issue.record("expected a container with two children")
            return
        }
        guard case .row(let row) = children[1] else {
            Issue.record("expected a row")
            return
        }
        #expect(row.components[0].destination == "https://example.test/o")
    }

    /// The accessory is the one recursive key, and Swift cannot lay out a struct
    /// that recursively contains itself — so it is decoded by hand into a box.
    @Test("A section's thumbnail accessory decodes")
    func sectionAccessory() throws {
        let nodes = try tree("""
        [{"type":9,"components":[{"type":10,"content":"Body"}],
          "accessory":{"type":11,"media":{"url":"https://example.test/t.png"}}}]
        """)
        guard case .section(let children, let thumbnail) = nodes[0] else {
            Issue.record("expected a section")
            return
        }
        #expect(children.count == 1)
        #expect(thumbnail?.url == "https://example.test/t.png")
    }

    @Test("A gallery keeps its items in order")
    func gallery() throws {
        let nodes = try tree("""
        [{"type":12,"items":[
          {"media":{"url":"https://example.test/1.png"}},
          {"media":{"url":"https://example.test/2.png"}}]}]
        """)
        guard case .gallery(let items) = nodes[0] else {
            Issue.record("expected a gallery")
            return
        }
        #expect(items.map(\.url) == ["https://example.test/1.png", "https://example.test/2.png"])
    }

    /// The tree grows without warning, and a node this client cannot draw must
    /// not cost the message the nodes beside it.
    @Test("An unknown node is skipped, and an empty one is dropped")
    func unknownAndEmpty() throws {
        let nodes = try tree("""
        [{"type":10,"content":"kept"},
         {"type":42,"content":"from the future"},
         {"type":17,"components":[]},
         {"type":10,"content":""}]
        """)
        #expect(nodes.count == 1)
        guard case .text(let value) = nodes[0] else {
            Issue.record("expected text")
            return
        }
        #expect(value == "kept")
    }

    /// One plain string per row, folded once — see `MarkdownDocument.plainText`.
    @Test("The tree folds to one spoken string")
    func plainText() throws {
        let nodes = try tree("""
        [{"type":17,"components":[
          {"type":10,"content":"Roadmap"},
          {"type":1,"components":[
            {"type":2,"style":5,"label":"Open","url":"https://example.test/o"}]}]}]
        """)
        #expect(nodes[0].plainText == "Roadmap\nOpen")
    }
}
