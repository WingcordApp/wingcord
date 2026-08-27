import AppKit
import CoreGraphics
import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// An embed is the most structurally complex thing the transcript draws, and
/// every rectangle in it is decided here rather than inside `draw`.
@MainActor
@Suite("Embed layout")
struct EmbedLayoutTests {

    private let style = MessageTextStyle.current()
    private let origin = CGPoint(x: 0, y: 0)

    private func layout(_ embed: Embed, width: CGFloat = 400) -> EmbedSlot {
        EmbedLayoutEngine.layout(
            embed,
            origin: origin,
            availableWidth: width,
            style: style,
            mentions: MentionContext(),
            parser: MarkdownParser()
        )
    }

    @Test("A card is capped at the embed width, never the column's")
    func widthIsCapped() {
        let slot = layout(Embed(title: "Release", description: "Notes"), width: 900)
        #expect(slot.rect.width == Metrics.embedMaxWidth)
    }

    @Test("A narrow column shrinks the card rather than overflowing it")
    func narrowColumn() {
        let slot = layout(Embed(title: "Release", description: "Notes"), width: 200)
        #expect(slot.rect.width == 200)
    }

    @Test("Every part contributes something to draw")
    func partsArePresent() {
        let slot = layout(Embed(
            title: "Lumen Club v0.1.5",
            description: "Seamless release-track switching",
            author: Embed.Author(name: "Lumen Club", iconURL: "https://example.test/a.png"),
            footer: Embed.Footer(text: "Nightly"),
            image: Embed.Media(url: "https://example.test/i.png", width: 800, height: 400),
            thumbnail: Embed.Media(url: "https://example.test/t.png")
        ))
        // Author, title, description, footer.
        #expect(slot.texts.count == 4)
        // Author mark, thumbnail, image.
        #expect(slot.images.count == 3)
    }

    /// **The case `Embed.isBareImage` exists for.** A pasted image link unfurls
    /// into a picture, and drawing a bordered card with twelve points of padding
    /// around a photograph is a frame nobody asked for.
    @Test("A bare image embed is the picture and nothing else")
    func bareImageHasNoCard() {
        let slot = layout(Embed(image: Embed.Media(url: "https://example.test/i.png", width: 400, height: 200)))
        #expect(slot.texts.isEmpty)
        #expect(slot.images.count == 1)
        #expect(slot.accent == nil)
        // The picture fills the slot exactly: no padding, no rule.
        #expect(slot.images[0].rect == slot.rect)
    }

    @Test("An unset accent draws no rule")
    func zeroAccentIsNoAccent() {
        #expect(layout(Embed(title: "x", colorValue: 0)).accent == nil)
        #expect(layout(Embed(title: "x", colorValue: 0x5865F2)).accent != nil)
    }

    /// Consecutive inline fields share a row, and a run of four wraps rather
    /// than squeezing a fourth column in.
    @Test("Inline fields share a row, three at a time")
    func inlineFieldsShareARow() {
        func field(_ name: String, inline: Bool) -> Embed.Field {
            Embed.Field(name: name, value: "v", isInline: inline)
        }
        let three = layout(Embed(fields: [
            field("a", inline: true), field("b", inline: true), field("c", inline: true),
        ]))
        // Three names on one y, and three values on another.
        let nameTops = Set(three.texts.map { $0.origin.y })
        #expect(nameTops.count == 2)

        let four = layout(Embed(fields: [
            field("a", inline: true), field("b", inline: true),
            field("c", inline: true), field("d", inline: true),
        ]))
        #expect(Set(four.texts.map { $0.origin.y }).count == 4)
    }

    @Test("A block field takes the whole width on its own row")
    func blockFieldTakesItsOwnRow() {
        let slot = layout(Embed(fields: [
            Embed.Field(name: "a", value: "v", isInline: false),
            Embed.Field(name: "b", value: "v", isInline: false),
        ]))
        #expect(Set(slot.texts.map { $0.origin.x }).count == 1)
    }

    /// The card has to be tall enough for everything in it, or the row beneath
    /// draws over its footer.
    @Test("The card encloses every part it holds")
    func cardEnclosesItsParts() {
        let slot = layout(Embed(
            title: "Release",
            description: String(repeating: "A long line of notes. ", count: 20),
            footer: Embed.Footer(text: "Nightly"),
            fields: [Embed.Field(name: "Build", value: "1234", isInline: true)]
        ))
        for text in slot.texts {
            #expect(text.origin.y + text.block.size.height <= slot.rect.maxY)
        }
        for image in slot.images {
            #expect(image.rect.maxY <= slot.rect.maxY)
        }
    }

    /// A thumbnail sits beside the text, so the text has to be narrowed for it —
    /// otherwise the description runs underneath the picture.
    @Test("A thumbnail narrows the text beside it")
    func thumbnailNarrowsTheText() {
        let wide = layout(Embed(title: "A reasonably long embed title here"))
        let withThumb = layout(Embed(
            title: "A reasonably long embed title here",
            thumbnail: Embed.Media(url: "https://example.test/t.png")
        ))
        let wideTitle = wide.texts[0].block.size.width
        let narrowTitle = withThumb.texts[0].block.size.width
        #expect(narrowTitle < wideTitle)
    }
}
