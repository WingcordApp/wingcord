import Testing
import WingcordCore
@testable import Wingcord

/// A channel link in prose — an event's place, its description, a bio — is
/// drawn as Discord's chip naming the place, "🔒 No Access" where the reader
/// cannot see it (Alex's images 50 and 51), in the transcript's rules.
@Suite("Channel chips in prose")
@MainActor
struct ProseChannelChipTests {
    private let iris = GuildID(rawValue: 10)
    private let elsewhere = GuildID(rawValue: 20)
    private let general = ChannelID(rawValue: 100)
    private let mods = ChannelID(rawValue: 101)
    private let support = ChannelID(rawValue: 102)
    private let hangout = ChannelID(rawValue: 103)
    private let news = ChannelID(rawValue: 200)

    private var context: MentionContext {
        var context = MentionContext()
        context.currentGuildID = iris
        context.guildNames = [iris: "Iris", elsewhere: "Elsewhere"]
        context.channels = [
            general: channel("general", in: iris, .text),
            mods: channel("mods", in: iris, .text, canView: false),
            support: channel("Support", in: iris, .category),
            hangout: channel("hangout", in: iris, .voice),
            news: channel("news", in: elsewhere, .text),
        ]
        return context
    }

    private func channel(_ name: String, in guild: GuildID, _ kind: ChannelKind, canView: Bool = true) -> LinkChannel {
        LinkChannel(name: name, guildID: guild, kind: kind, canView: canView, isPost: false, parentID: nil)
    }

    private func url(_ guild: UInt64, _ channel: UInt64, message: UInt64? = nil) -> String {
        "https://discord.com/channels/\(guild)/\(channel)" + (message.map { "/\($0)" } ?? "")
    }

    /// The one segment a node becomes.
    private func segment(_ node: InlineNode, mentions: MentionContext?) -> ProseSegment.Kind? {
        ProseSegment.lines(of: [node], style: .body, mentions: mentions).first?.first?.kind
    }

    private func chip(_ node: InlineNode) -> (parts: [ProseChipPart], destination: String?)? {
        guard case .chip(let parts, _, let destination) = segment(node, mentions: context) else { return nil }
        return (parts, destination)
    }

    private let chevron: [ProseChipPart] = [.text(" "), .symbol("chevron.compact.right"), .text(" ")]

    @Test("A channel the reader cannot see is \"🔒 No Access\", and goes nowhere")
    func noAccess() {
        let drawn = chip(.autoLink(url(10, 101)))
        #expect(drawn?.parts == [.symbol("lock.fill"), .text(" No Access")])
        #expect(drawn?.destination == nil)
        // A `<#id>` runs through the same rule.
        #expect(chip(.channelMention(mods))?.parts == [.symbol("lock.fill"), .text(" No Access")])
    }

    @Test("A channel in this server is its name, and opens it")
    func sameServer() {
        let link = url(10, 100)
        let drawn = chip(.autoLink(link))
        #expect(drawn?.parts == [.text("#general")])
        #expect(drawn?.destination == link)
        #expect(chip(.autoLink(url(10, 103)))?.parts == [.symbol(ChannelKind.voice.symbolName), .text(" hangout")])
        #expect(chip(.autoLink(url(10, 100, message: 5)))?.parts
            == [.text("#general")] + chevron + [.symbol("text.bubble.fill")])
    }

    @Test("Another server's channel names its server first")
    func otherServer() {
        #expect(chip(.autoLink(url(20, 200)))?.parts == [.text("Elsewhere")] + chevron + [.text("#news")])
        #expect(chip(.autoLink(url(20, 200, message: 7)))?.parts
            == [.text("Elsewhere")] + chevron + [.symbol("text.bubble.fill")])
    }

    @Test("A channel nobody here can name reads unknown, after its server")
    func unknown() {
        let link = url(20, 999)
        let drawn = chip(.autoLink(link))
        #expect(drawn?.parts == [.text("Elsewhere")] + chevron + [.text("#"), .text("unknown", italic: true)])
        #expect(drawn?.destination == link)
    }

    @Test("A category is plain text, and a link with no session stays a link")
    func plainCases() {
        guard case .word(let words, let style, let destination) = segment(.autoLink(url(10, 102)), mentions: context) else {
            Issue.record("a category should be plain words")
            return
        }
        #expect(words == "#Support")
        #expect(style.plate == nil)
        #expect(destination == nil)

        let link = url(10, 101)
        guard case .word(let raw, _, let opens) = segment(.autoLink(link), mentions: nil) else {
            Issue.record("with no session a link should stay a link")
            return
        }
        #expect(raw == link)
        #expect(opens == link)
    }

    @Test("A link that is not Discord's is untouched")
    func otherLinks() {
        let link = "https://example.com/channels/10/100"
        guard case .word(let words, _, let destination) = segment(.autoLink(link), mentions: context) else {
            Issue.record("a web link should stay a link")
            return
        }
        #expect(words == link)
        #expect(destination == link)
    }
}
