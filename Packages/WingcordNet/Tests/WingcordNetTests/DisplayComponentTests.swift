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

    /// An embed of type `components`, which Discord's unfurler sends for a site
    /// that describes itself as a Components V2 card. `MessageAccessories`
    /// draws the tree in place of the embed's card; the normalizer keeps it by
    /// the same parse a message's own tree goes through (module `659674`).
    @Test("An embed carries its components as a tree")
    func embedComponents() throws {
        let json = """
        {"type":"components","url":"https://lumen.example","components":[
          {"type":17,"components":[
            {"type":10,"content":"## Lumen Club"},
            {"type":1,"components":[{"type":2,"style":5,"label":"Website","url":"https://lumen.example"}]}
          ]}
        ]}
        """
        let embed = try JSONDecoder().decode(EmbedDTO.self, from: Data(json.utf8)).domain
        #expect(embed.kind == "components")
        guard case .container(_, let children)? = embed.components.first else {
            Issue.record("the embed's tree should open with its container")
            return
        }
        #expect(children.count == 2)
        #expect(children.first == .text("## Lumen Club"))
    }

    /// **The capture itself** — the components capture, the card as
    /// Discord's unfurler sent it, every field intact: ids, spoiler flags, the
    /// picture's placeholder, content type and alt text.
    @Test("The captured card decodes whole")
    func capturedCard() throws {
        let json = #"""
        {"type": "components", "url": "https://example.com/", "content_scan_version": 4, "components": [{"type": 17, "id": 1, "accent_color": 15702980, "components": [{"type": 10, "id": 2, "content": "# Lumen\nA made-up app's card: a heading, a picture and three links, as Discord's unfurler sends them."}, {"type": 12, "id": 3, "items": [{"media": {"id": "1551005927971902216", "url": "https://example.com/preview.png", "proxy_url": "https://images-ext-1.discordapp.net/external/example/https/example.com/preview.png", "width": 3200, "height": 1680, "placeholder": "iAcGDIAYRWhwlnl5h3jXj3X5uA==", "placeholder_version": 1, "content_type": "image/png", "loading_state": 1, "flags": 0}, "description": "Lumen running on a MacBook beneath the Lumen wordmark", "spoiler": false}]}, {"type": 1, "id": 4, "components": [{"type": 2, "id": 5, "style": 5, "label": "Website", "url": "https://example.com"}, {"type": 2, "id": 6, "style": 5, "label": "GitHub", "url": "https://github.com/example/lumen"}, {"type": 2, "id": 7, "style": 5, "label": "Discord", "url": "https://discord.gg/example"}]}], "spoiler": false}]}
        """#
        let embed = try JSONDecoder().decode(EmbedDTO.self, from: Data(json.utf8)).domain
        guard case .container(let accent, let children)? = embed.components.first else {
            Issue.record("the card should open with its container")
            return
        }
        #expect(accent == 15_702_980)
        #expect(children.count == 3)
        guard case .gallery(let items) = children[1] else {
            Issue.record("the second child should be the gallery")
            return
        }
        #expect(items.first?.width == 3200)
        #expect(items.first?.placeholder == "iAcGDIAYRWhwlnl5h3jXj3X5uA==")
        #expect(items.first?.altText == "Lumen running on a MacBook beneath the Lumen wordmark")
        #expect(items.first?.isVideo == false)
        #expect(items.first?.isSpoiler == false)
        guard case .row(let row) = children[2] else {
            Issue.record("the third child should be the buttons")
            return
        }
        #expect(row.components.map(\.label) == ["Website", "GitHub", "Discord"])
    }

    @Test("A gallery item knows it is a video, and a spoiler")
    func galleryItemFacts() throws {
        let nodes = try tree("""
        [{"type":12,"items":[
          {"media":{"url":"https://cdn.discordapp.com/attachments/1/2/clip.mp4","proxy_url":"https://media.discordapp.net/attachments/1/2/clip.mp4","width":1280,"height":720,"content_type":"video/mp4"}},
          {"media":{"url":"https://cdn.discordapp.com/attachments/1/3/a.png","width":10,"height":10},"spoiler":true}]}]
        """)
        guard case .gallery(let items)? = nodes.first else {
            Issue.record("expected a gallery")
            return
        }
        #expect(items[0].isVideo)
        #expect(!items[0].isSpoiler)
        #expect(items[1].isSpoiler)
    }

    /// Copy Text on an app's message: its content is empty, so what it says is
    /// its text displays, inside containers and sections too.
    @Test("A component tree's text reads in order, a blank line apart")
    func plainTextOfATree() {
        let tree: [DisplayComponent] = [
            .container(accent: nil, children: [
                .text("How to Set Up"),
                .separator(isDivider: true, isLarge: false),
                .section(children: [.text("Server Hub gives your server…")], thumbnail: nil),
            ]),
            .text("Important: an experiment."),
        ]
        #expect(DisplayComponent.plainText(of: tree)
            == "How to Set Up\n\nServer Hub gives your server…\n\nImportant: an experiment.")
        #expect(DisplayComponent.plainText(of: []).isEmpty)
    }
}
