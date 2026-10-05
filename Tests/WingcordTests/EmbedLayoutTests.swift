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

    // MARK: Videos

    /// A YouTube unfurl, the shape Discord sends: a `video` with the site as
    /// provider, the channel as author, and the watch page as the URL.
    private func youtube(video: String = "https://www.youtube.com/embed/dQw4w9WgXcQ") -> Embed {
        Embed(
            title: "A video",
            kind: "video",
            description: "What the uploader wrote under it.",
            url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            author: Embed.Author(name: "A channel", url: "https://www.youtube.com/@channel"),
            thumbnail: Embed.Media(url: "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg", width: 480, height: 360),
            video: Embed.Media(url: video, width: 1280, height: 720),
            providerName: "YouTube"
        )
    }

    @Test("A YouTube video is a card with its thumbnail as the media, Play and Open Link on it")
    func youtubeCard() throws {
        let slot = layout(youtube())
        #expect(slot.drawsCard)
        let media = try #require(slot.images.first { $0.controls != nil })
        guard case .player(let player) = media.video else {
            Issue.record("the thumbnail should start a player")
            return
        }
        let items = URLComponents(url: player, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.contains(URLQueryItem(name: "autoplay", value: "1")))
        #expect(player.host() == "www.youtube.com")
        #expect(media.controls?.page.absoluteString == "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        // The video's own shape, and no corner thumbnail beside it.
        #expect(abs(media.rect.width / media.rect.height - 16.0 / 9.0) < 0.02)
        #expect(slot.images.filter { $0.rect.width == EmbedLayoutEngine.thumbnailSide }.isEmpty)
        // Discord's `Mg`: a video says nothing below its title.
        #expect(!slot.texts.contains { $0.block.text.attributed.string.contains("uploader") })
    }

    @Test("A player on somebody else's host is not started")
    func lookAlikePlayer() {
        let slot = layout(youtube(video: "https://www.youtube.com.evil.test/embed/x"))
        #expect(slot.images.allSatisfy { $0.controls == nil })
    }

    @Test("Twitch is told the hosts it is framed by")
    func twitchParents() throws {
        var embed = youtube(video: "https://player.twitch.tv/?channel=somebody&parent=meta.tag")
        embed.providerName = "Twitch"
        let player = try #require(EmbedLayoutEngine.playerURL(for: embed))
        let parents = URLComponents(url: player, resolvingAgainstBaseURL: false)?.queryItems?
            .filter { $0.name == "parent" }.compactMap(\.value) ?? []
        #expect(parents.contains("discord.com"))
        #expect(!parents.contains("meta.tag"))
    }

    /// Enough words to reach any cap: a card is as wide as its content
    /// (`max-content`), so only a long one shows where the cap is.
    private let notes = String(repeating: "Everything that changed in this release, and why. ", count: 6)

    @Test("A card is capped at Discord's 516 and its rule, never the column's")
    func widthIsCapped() {
        let slot = layout(Embed(title: "Release", description: notes), width: 900)
        #expect(slot.rect.width == EmbedLayoutEngine.ruleWidth + EmbedLayoutEngine.maxWidth)
    }

    @Test("A narrow column shrinks the card rather than overflowing it")
    func narrowColumn() {
        let slot = layout(Embed(title: "Release", description: notes), width: 200)
        #expect(slot.rect.width == 200)
    }

    @Test("A card with little in it is as wide as that, and no wider")
    func fitsItsContent() {
        let slot = layout(Embed(title: "Release", description: "Notes"), width: 900)
        #expect(slot.rect.width < 200)
        #expect(slot.texts.allSatisfy { slot.rect.maxX >= $0.origin.x + EmbedLayoutEngine.usedWidth(of: $0.block) })
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

    /// **The shape a real link unfurl takes**, and the one the enclosure test
    /// above could not see: Discord's Spotify embed is a title, a provider and a
    /// 300x300 thumbnail with *no description at all*. The card's height came
    /// from the text alone, so it was drawn about forty points tall with an
    /// eighty-point picture in it and the cover hung out of the bottom edge.
    ///
    /// Captured, `spotify embed.har`:
    ///
    /// ```json
    /// { "type": "link", "title": "Lounge Act",
    ///   "provider": { "name": "Spotify" },
    ///   "thumbnail": { "width": 300, "height": 300, … } }
    /// ```
    @Test("A card with a thumbnail and one line of text still encloses the picture")
    func shortCardEnclosesItsThumbnail() {
        let slot = layout(Embed(
            title: "Lounge Act",
            url: "https://open.spotify.com/track/7glld4kxYHp61zIPtSVHNk",
            thumbnail: Embed.Media(url: "https://example.test/cover.png"),
            providerName: "Spotify"
        ))
        #expect(!slot.images.isEmpty)
        for image in slot.images {
            #expect(image.rect.maxY <= slot.rect.maxY)
        }
        // And the picture is not merely inside it — the card has the padding
        // below it that every other card has.
        let picture = slot.images[0]
        #expect(slot.rect.maxY - picture.rect.maxY >= EmbedLayoutEngine.padding)
    }

    // MARK: A music card

    /// The card behind a Spotify link, from the fields Spotify's own embed page
    /// answers with — none of which are in the embed Discord sends.
    private let loungeAct = SpotifyUnfurl(
        kind: .track,
        id: "7glld4kxYHp61zIPtSVHNk",
        title: "Lounge Act",
        subtitle: "Nirvana",
        coverURL: URL(string: "https://i.scdn.co/image/300.jpg"),
        accentValue: 0x00_52_99,
        isExplicit: true,
        durationMilliseconds: 156_426,
        previewURL: URL(string: "https://p.scdn.co/mp3-preview/c4eb66")
    )

    private func spotifyEmbed() -> Embed {
        Embed(
            title: "Lounge Act",
            kind: "link",
            url: "https://open.spotify.com/track/7glld4kxYHp61zIPtSVHNk",
            thumbnail: Embed.Media(url: "https://example.test/cover.png"),
            providerName: "Spotify"
        )
    }

    @Test("A resolved card replaces the link unfurl and carries its own controls")
    func musicCard() throws {
        let slot = EmbedLayoutEngine.layout(
            spotifyEmbed(),
            origin: .zero,
            availableWidth: 400,
            style: style,
            mentions: MentionContext(),
            parser: MarkdownParser(),
            spotify: loungeAct
        )
        // The rule takes the colour Spotify quantised from the artwork.
        #expect(slot.accent != nil)
        #expect(slot.previewURL?.host() == "p.scdn.co")
        #expect(slot.chips.contains { $0.kind == .preview })
        #expect(slot.chips.contains { $0.kind == .explicit })
        // The cover, at the card's own square.
        #expect(slot.images.count == 1)
        #expect(slot.images[0].rect.width == EmbedLayoutEngine.coverSide)
        // The way into Spotify's own player — the only route to a full track
        // and to the library, neither of which this client can offer.
        #expect(slot.chips.contains { $0.kind == .open })
        #expect(slot.spotify?.id == "7glld4kxYHp61zIPtSVHNk")
    }

    /// Every chip is inside the card it belongs to, and none of them overlaps
    /// another — the hit test reads these rects, so an overlap is a control that
    /// answers for its neighbour.
    @Test("The controls sit inside the card and do not overlap")
    func chipsDoNotOverlap() {
        let slot = EmbedLayoutEngine.layout(
            spotifyEmbed(),
            origin: .zero,
            availableWidth: 400,
            style: style,
            mentions: MentionContext(),
            parser: MarkdownParser(),
            spotify: loungeAct
        )
        for chip in slot.chips {
            #expect(slot.rect.contains(chip.rect))
        }
        for (index, chip) in slot.chips.enumerated() {
            for other in slot.chips[(index + 1)...] {
                #expect(!chip.rect.intersects(other.rect))
            }
        }
    }

    /// A narrow column is where a control row runs into the trailing chip. The
    /// row wins: a control drawn over a duration is two things in one place.
    @Test("A card too narrow for the Open chip simply has none")
    func narrowCardDropsTheOpenChip() {
        let slot = EmbedLayoutEngine.layout(
            spotifyEmbed(),
            origin: .zero,
            availableWidth: 190,
            style: style,
            mentions: MentionContext(),
            parser: MarkdownParser(),
            spotify: loungeAct
        )
        for (index, chip) in slot.chips.enumerated() {
            for other in slot.chips[(index + 1)...] {
                #expect(!chip.rect.intersects(other.rect))
            }
        }
    }

    /// **The whole reason the card has a height rule of its own.** A track with
    /// a short name has less text than the cover is tall, and a card measured by
    /// its text alone would hang the artwork out of the bottom — which is
    /// exactly the defect the link unfurl had.
    @Test("The card encloses its cover even when the text is shorter")
    func musicCardEnclosesItsCover() {
        let slot = EmbedLayoutEngine.layout(
            spotifyEmbed(),
            origin: .zero,
            availableWidth: 400,
            style: style,
            mentions: MentionContext(),
            parser: MarkdownParser(),
            spotify: SpotifyUnfurl(kind: .artist, id: "a", title: "X")
        )
        for image in slot.images {
            #expect(image.rect.maxY <= slot.rect.maxY)
        }
        #expect(slot.rect.height >= EmbedLayoutEngine.coverSide)
    }

    /// **Nil is the ordinary state**: before the fetch lands, and for ever if
    /// Spotify's page changes shape. The transcript keeps the card Discord sent,
    /// which is quieter and correct.
    @Test("An unresolved Spotify link draws the link unfurl Discord sent")
    func unresolvedSpotifyLinkFallsBack() {
        let slot = layout(spotifyEmbed())
        #expect(slot.chips.isEmpty)
        #expect(slot.previewURL == nil)
        // Still a proper card: title, and a thumbnail it encloses.
        #expect(slot.drawsCard)
        for image in slot.images {
            #expect(image.rect.maxY <= slot.rect.maxY)
        }
    }

    /// An entity with no clip has no chip rather than a dead one — §5.5.
    @Test("A card with no preview offers no Preview")
    func noPreviewNoChip() {
        let slot = EmbedLayoutEngine.layout(
            spotifyEmbed(),
            origin: .zero,
            availableWidth: 400,
            style: style,
            mentions: MentionContext(),
            parser: MarkdownParser(),
            spotify: SpotifyUnfurl(kind: .artist, id: "a", title: "Nirvana")
        )
        #expect(!slot.chips.contains { $0.kind == .preview })
        #expect(slot.previewURL == nil)
    }

    // MARK: The star on an unfurled GIF

    /// **The real thing, out of `search messages1.har`.** A Klipy unfurl is
    /// `type: "gifv"` with a **`.webp`** thumbnail and an `.mp4` beside it — not
    /// the `.gif` an invented fixture would have used, and the reason the first
    /// gate here was wrong: `CDN.canAnimate` answers on the extension, so a rule
    /// written on "does it animate" gave Tenor a star and gave this nothing.
    private static let klipyGIF = Embed(
        kind: "gifv",
        url: "https://klipy.com/gifs/sonion-ring",
        thumbnail: Embed.Media(
            url: "https://static.klipy.com/ii/…/C61hYOA7sIGTLuZ9.webp",
            proxyURL: "https://images-ext-1.discordapp.net/external/…/C61hYOA7sIGTLuZ9.webp",
            width: 449,
            height: 480
        ),
        video: Embed.Media(
            url: "https://static.klipy.com/ii/…/RzT4TfvPG9vQ.mp4",
            proxyURL: "https://images-ext-1.discordapp.net/external/…/RzT4TfvPG9vQ.mp4",
            width: 450,
            height: 480
        ),
        providerName: "Klipy"
    )

    @Test("An unfurled GIF can be starred, whatever its thumbnail's extension is")
    func unfurledGIFIsStarrable() throws {
        let slot = layout(Self.klipyGIF)
        let gif = try #require(slot.favorite)
        // **The page URL is the key**: that is what the message says, what the
        // favourite is filed under, and what re-sending it puts back.
        #expect(gif.url.absoluteString == "https://klipy.com/gifs/sonion-ring")
        // Never the `.mp4` — nothing in the image path can open one, and a
        // favourite pointing at one is a grey tile in the picker for ever.
        #expect(gif.previewURL?.pathExtension == "webp")
        #expect(gif.width == 449)
    }

    /// The star sits inside the picture, and the hit test and the painter are
    /// handed the same rect — a control drawn in one place and clicked in
    /// another is the defect this geometry produces.
    @Test("The star sits inside the picture it belongs to")
    func starIsInsideThePicture() {
        let slot = layout(Self.klipyGIF)
        #expect(slot.rect.contains(slot.favoriteRect))
        #expect(slot.favoriteRect.width > 0)
    }

    /// A photograph has nothing to favourite: the entry is stored as a URL and
    /// re-sent, and a still is not a GIF. Nil is what keeps the control off it
    /// rather than drawing it disabled — §5.5.
    @Test("A still picture has no star")
    func stillPictureHasNoStar() {
        let slot = layout(Embed(
            kind: "image",
            url: "https://example.test/photo.png",
            thumbnail: Embed.Media(
                url: "https://example.test/photo.png", width: 800, height: 600
            )
        ))
        #expect(slot.favorite == nil)
    }

    /// A card is not a picture. The star belongs on the GIF itself, and a link
    /// unfurl with a thumbnail in the corner has no picture to put it on.
    @Test("A card with a thumbnail has no star")
    func cardHasNoStar() {
        let slot = layout(Embed(
            title: "Lounge Act",
            url: "https://open.spotify.com/track/7glld4kxYHp61zIPtSVHNk",
            thumbnail: Embed.Media(url: "https://example.test/cover.png"),
            providerName: "Spotify"
        ))
        #expect(slot.favorite == nil)
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

    // MARK: Discord's measures (`198496`)

    @Test("A thumbnail is fitted inside 80 by 80, never cropped; one of no known shape is the square")
    func thumbnailKeepsItsShape() throws {
        let wide = layout(Embed(
            title: "Wide",
            thumbnail: Embed.Media(url: "https://example.test/w.png", width: 1600, height: 900)
        ), width: 600)
        let box = try #require(wide.images.first?.rect)
        #expect(box.size == CGSize(width: 80, height: 45))
        let unknown = layout(Embed(title: "Unknown", thumbnail: Embed.Media(url: "https://example.test/u.png")))
        #expect(unknown.images.first?.rect.size == CGSize(width: 80, height: 80))
    }

    @Test("Ten above the first part, sixteen under the last, and sixteen above the media")
    func padding() throws {
        let titled = layout(Embed(title: "Release"))
        let title = try #require(titled.texts.first)
        #expect(title.origin.y == origin.y + 10)
        #expect(titled.rect.maxY == title.origin.y + title.block.size.height + 16)

        let pictured = layout(Embed(
            title: "Release",
            image: Embed.Media(url: "https://example.test/i.png", width: 800, height: 400)
        ), width: 600)
        let heading = try #require(pictured.texts.first)
        let picture = try #require(pictured.images.first)
        #expect(picture.rect.minY == heading.origin.y + heading.block.size.height + 16)
        #expect(picture.corner == EmbedLayoutEngine.cardCorner)
    }

    @Test("The description is Discord's text-sm, the title its 1rem")
    func typeSizes() throws {
        let slot = layout(Embed(title: "Release", description: "What changed"))
        func size(_ index: Int) throws -> CGFloat {
            let text = slot.texts[index].block.text.attributed
            let font = try #require(text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
            return font.pointSize
        }
        #expect(try size(0) == style.bodyFont.pointSize)
        #expect(abs(try size(1) - style.bodyFont.pointSize * EmbedLayoutEngine.smallScale) < 0.01)
    }

    @Test("The footer's time is in the transcript's calendar words")
    func footerStamp() {
        let slot = EmbedLayoutEngine.layout(
            Embed(timestamp: Date(timeIntervalSince1970: 0), footer: Embed.Footer(text: "Bot")),
            origin: origin,
            availableWidth: 400,
            style: style,
            mentions: MentionContext(),
            parser: MarkdownParser(),
            footerStamp: "Today at 4:21 AM"
        )
        #expect(slot.texts.last?.block.text.attributed.string == "Bot \u{2022} Today at 4:21 AM")
    }
}
