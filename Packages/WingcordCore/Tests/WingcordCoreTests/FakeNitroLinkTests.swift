import Foundation
import Testing
@testable import WingcordCore

/// Fake Nitro links, drawn as what they stand for — the FMOG fix (decision
/// 10), held to the plugin's own receiving rules.
@Suite("Fake Nitro links")
struct FakeNitroLinkTests {

    private let fmog = "https://cdn.discordapp.com/emojis/111.webp?size=48&name=FMOG&lossless=true"
    private let wave = "https://media.discordapp.net/stickers/222.png?size=160&name=wave&lossless=true"

    @Test("An emoji link is read for its id, name and motion; a sticker's for its own")
    func parses() {
        #expect(FakeNitroLink(url: fmog) == .emoji(EmojiRef(id: EmojiID(rawValue: 111), name: "FMOG", isAnimated: false)))
        #expect(FakeNitroLink(url: "https://cdn.discordapp.com/emojis/5.gif?size=48&name=dance")
            == .emoji(EmojiRef(id: EmojiID(rawValue: 5), name: "dance", isAnimated: true)))
        #expect(FakeNitroLink(url: "https://cdn.discordapp.com/emojis/5.webp?animated=true", label: "dance")
            == .emoji(EmojiRef(id: EmojiID(rawValue: 5), name: "dance", isAnimated: true)))
        #expect(FakeNitroLink(url: wave) == .sticker(StickerRef(id: 222, name: "wave", format: .png)))
    }

    @Test("Only Discord's CDN, and only its emoji and sticker paths")
    func refuses() {
        #expect(FakeNitroLink(url: "https://example.com/emojis/111.webp?name=FMOG") == nil)
        #expect(FakeNitroLink(url: "https://cdn.discordapp.com/attachments/1/2/cat.png") == nil)
        #expect(FakeNitroLink(url: "https://cdn.discordapp.com/emojis/abc.webp") == nil)
    }

    /// The report: the name above the picture. Now the emoji, and alone it is
    /// jumbo, as a real one would be.
    @Test("A masked or bare emoji link is the emoji, in a sentence or alone")
    func drawsInline() {
        let alone = MarkdownParser().parse("[FMOG](\(fmog))")
        #expect(alone.jumboEmojiCount == 1)
        let bare = MarkdownParser().parse(fmog)
        #expect(bare.jumboEmojiCount == 1)
        let sentence = MarkdownParser().parse("look [FMOG](\(fmog)) here")
        guard case .paragraph(let nodes) = sentence.blocks.first else {
            Issue.record("a paragraph")
            return
        }
        #expect(nodes.contains(.customEmoji(EmojiRef(id: EmojiID(rawValue: 111), name: "FMOG", isAnimated: false))))
        #expect(!nodes.contains { if case .link = $0 { true } else { false } })
    }

    @Test("A sticker link is a sticker, its unfurl is hidden, and its words leave nothing")
    func stickers() {
        let unfurl = Embed(kind: "image", url: wave, thumbnail: Embed.Media(url: wave, width: 160, height: 160))
        let message = Message(
            id: MessageID(rawValue: 1),
            channelID: ChannelID(rawValue: 2),
            authorID: UserID(rawValue: 3),
            content: "[wave](\(wave))",
            payload: MessagePayload(embeds: [unfurl])
        )
        #expect(message.displayedStickers == [StickerRef(id: 222, name: "wave", format: .png)])
        #expect(message.drawableEmbeds.isEmpty)
        #expect(message.displayedContent.isEmpty)

        let sentence = Message(
            id: MessageID(rawValue: 4),
            channelID: ChannelID(rawValue: 2),
            authorID: UserID(rawValue: 3),
            content: "hi [wave](\(wave))"
        )
        #expect(sentence.displayedContent == "hi [wave](\(wave))", "words around it stay; the scanner drops the link")
    }
}

/// Sending, in the plugin's own format.
@Suite("Fake Nitro sending")
struct FakeNitroSendTests {

    @Test("An unusable emoji becomes the plugin's link, padded off its neighbours; a usable one stays")
    func emoji() {
        let content = "hi<:FMOG:111>and <a:dance:5> <:mine:9>"
        let sent = FakeNitroSend.replacingEmoji(in: content) { $0.id?.rawValue != 9 }
        #expect(sent == "hi [FMOG](https://cdn.discordapp.com/emojis/111.webp?size=48&name=FMOG&lossless=true) and "
            + "[dance](https://cdn.discordapp.com/emojis/5.gif?size=48&name=dance&lossless=true) <:mine:9>")
        // And it reads back as the emoji it was.
        #expect(FakeNitroLink.links(in: sent).count == 2)
    }

    @Test("An escaped emoji is left as written")
    func escaped() {
        #expect(FakeNitroSend.replacingEmoji(in: #"\<:FMOG:111>"#) { _ in true } == #"\<:FMOG:111>"#)
    }

    @Test("A sticker is appended as its link, and a Lottie one cannot be")
    func sticker() throws {
        let link = try #require(FakeNitroSend.link(for: StickerRef(id: 222, name: "wave", format: .png)))
        #expect(link == "[wave](https://media.discordapp.net/stickers/222.png?size=160&name=wave&lossless=true)")
        #expect(FakeNitroSend.appending(link, to: "look") == "look " + link)
        #expect(FakeNitroSend.appending(link, to: "") == link)
        #expect(FakeNitroSend.link(for: StickerRef(id: 3, name: "x", format: .lottie)) == nil)
        #expect(FakeNitroLink(url: "https://media.discordapp.net/stickers/222.png?size=160&name=wave&lossless=true")
            == .sticker(StickerRef(id: 222, name: "wave", format: .png)))
    }

    /// The plugin's animated sticker, uploaded as `<sticker id>.gif`.
    @Test("A GIF named for a sticker on Discord's attachments CDN stands for it")
    func gifSticker() {
        func attachment(_ url: String, type: String? = "image/gif") -> WingcordCore.Attachment {
            WingcordCore.Attachment(
                id: AttachmentID(rawValue: 9), filename: String(url.split(separator: "/").last ?? ""),
                url: url, proxyURL: url, contentType: type
            )
        }
        #expect(FakeNitroLink.gifStickerID(in: attachment(
            "https://cdn.discordapp.com/attachments/10/20/749054660769218631.gif?ex=1"
        )) == 749_054_660_769_218_631)
        // Not a number, not a GIF, or somewhere else: just a file.
        #expect(FakeNitroLink.gifStickerID(in: attachment("https://cdn.discordapp.com/attachments/10/20/party.gif")) == nil)
        #expect(FakeNitroLink.gifStickerID(in: attachment(
            "https://cdn.discordapp.com/attachments/10/20/123.png", type: "image/png"
        )) == nil)
        #expect(FakeNitroLink.gifStickerID(in: attachment("https://example.com/attachments/10/20/123.gif")) == nil)
    }

    @Test("An animated sticker is never sent as a link")
    func animatedStickerHasNoLink() {
        #expect(FakeNitroSend.link(for: StickerRef(id: 4, name: "spin", format: .apng)) == nil)
    }
}
