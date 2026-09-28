import AppKit
import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// Discord's inline and block formatting, driven through the real builder and
/// the real layout — the path a message in the transcript takes.
///
/// **Why each of these is pinned.** Every one was a surface that measured
/// perfectly and drew nothing: a spoiler covered in a colour that matched the
/// ground and laid out in clear ink, so neither state showed a word; a quote
/// whose rule was "painted by the row painter" and painted by nothing; a role
/// mention resolved against the wrong server.
@MainActor
@Suite("Message formatting")
struct MessageFormattingTests {

    private let style = MessageTextStyle.current(scale: 1)

    private func text(_ source: String, context: MentionContext = MentionContext()) -> MessageText {
        MessageTextBuilder.build(
            document: MarkdownParser().parse(source),
            context: context,
            style: style
        )
    }

    private func block(_ source: String, width: CGFloat = 400, context: MentionContext = MentionContext()) -> TimelineTextBlock {
        TimelineTextBlock(text: text(source, context: context), width: width, style: style)
    }

    @Test("A spoiler keeps its ink: the cover is painted over it, not the colour taken out")
    func spoilerKeepsItsInk() throws {
        let spoiler = text("||test||")
        let range = try #require(spoiler.spoilers.first)
        let ink = spoiler.attributed.attribute(.foregroundColor, at: range.location, effectiveRange: nil)
            as? NSColor
        #expect(ink != nil)
        #expect(ink?.alphaComponent ?? 0 > 0)
    }

    @Test("A spoiler that wraps is ONE spoiler on every line it crosses")
    func wrappedSpoilerIsOne() {
        let wrapped = block("||" + String(repeating: "wraps across lines ", count: 8) + "||", width: 160)
        #expect(wrapped.spoilerRects.count > 1)
        #expect(Set(wrapped.spoilerRects.map(\.spoiler)) == [0])
    }

    @Test("A quote draws a 4-point rule and its text starts past it")
    func quoteRule() throws {
        let quote = block("> test")
        let rule = try #require(quote.quoteRules.first)
        #expect(rule.minX == 0)
        #expect(rule.width == MessageTextStyle.quoteRuleWidth)
        #expect(rule.height > 0)
        #expect(quote.quoteRules.count == 1)
        // The words wrap inside the rule rather than under it.
        let lines = CTFrameGetLines(quote.frame) as? [CTLine] ?? []
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(quote.frame, CFRange(location: 0, length: 0), &origins)
        #expect(origins.first?.x ?? 0 >= MessageTextStyle.quoteIndent)
    }

    @Test("A quote's own text is the subtle ink")
    func quoteInk() {
        let quote = text("> test")
        let ink = quote.attributed.attribute(.foregroundColor, at: quote.attributed.length - 1, effectiveRange: nil)
            as? NSColor
        #expect(ink == style.secondaryColor)
    }

    @Test("Inline code sits on a code plate that covers its glyphs and its padding")
    func inlineCodePlate() throws {
        let code = block("`test`")
        let plate = try #require(code.plateRects.first)
        guard case .code = code.text.plates[plate.plate].kind else {
            Issue.record("expected a code plate")
            return
        }
        // The trailing air is kerned into the run, so the plate is wider than
        // the glyphs by the padding on both sides.
        let glyphs = CTLineGetTypographicBounds(
            (CTFrameGetLines(code.frame) as? [CTLine] ?? [])[0], nil, nil, nil
        )
        #expect(plate.rect.width >= CGFloat(glyphs))
        #expect(plate.rect.height > 0)
        #expect(plate.rect.height < code.size.height + 1)
    }

    @Test("A fenced block is one box across the block, never above its first line")
    func codeBlockBox() throws {
        let fenced = block("```\nlet x = 1\nlet y = 2\n```")
        let box = try #require(fenced.codeBlockRects.first)
        #expect(fenced.codeBlockRects.count == 1)
        #expect(box.width == 400)
        // The top padding lives inside the space the first line reserved.
        #expect(box.minY >= -0.5)
        #expect(box.maxY <= fenced.size.height + 0.5)
    }

    @Test("An unknown role is Discord's own words, as plain text")
    func unknownRole() {
        let unknown = text("<@&123>")
        #expect(unknown.attributed.string == "@unknown-role")
        #expect(unknown.plates.isEmpty)
        #expect(unknown.links.isEmpty)
    }

    @Test("A role with a colour gets its own plate; one without wears the mention's")
    func rolePlates() throws {
        var context = MentionContext()
        context.roles[RoleID(rawValue: 1)] = MentionRole(name: "refill", color: 0x9B_59_B6)
        context.roles[RoleID(rawValue: 2)] = MentionRole(name: "plain", color: nil)
        let coloured = text("<@&1>", context: context)
        #expect(coloured.attributed.string == "@refill")
        guard case .role = try #require(coloured.plates.first).kind else {
            Issue.record("expected a role plate")
            return
        }
        let plain = text("<@&2>", context: context)
        guard case .mention = try #require(plain.plates.first).kind else {
            Issue.record("expected the mention plate")
            return
        }
        #expect(plain.links.count == 1)
    }

    @Test("A timestamp is the text's own ink on a grey plate, not a mention")
    func timestampPlate() throws {
        let stamp = text("<t:1700000000:t>")
        guard case .timestamp = try #require(stamp.plates.first).kind else {
            Issue.record("expected a timestamp plate")
            return
        }
        let ink = stamp.attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(ink == style.primaryColor)
    }

    @Test("The mention table answers for every server, not only the selected one")
    func rolesResolveAcrossServers() {
        let model = AppModel()
        let elsewhere = GuildID(rawValue: 77)
        let roleID = RoleID(rawValue: 88)
        model.roles = [elsewhere: [roleID: Role(id: roleID, name: "refill")]]
        // Nothing selected — the inbox's case, where a row is from anywhere.
        #expect(model.mentionContext().roles[roleID]?.name == "refill")
    }
}
