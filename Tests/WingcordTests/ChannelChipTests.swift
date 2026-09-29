import AppKit
import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// Discord's channel chips — `F` and `k` beside `channelOrMessageUrl` in its
/// markdown rules — through the real builder, which is the path a message in
/// the transcript takes.
///
/// Inline marks are object-replacement characters in the string; which mark
/// each one is sits in `inlineSymbols`.
@MainActor
@Suite("Channel chips")
struct ChannelChipTests {

    private let style = MessageTextStyle.current(scale: 1)
    private static let mark = "\u{FFFC}"

    private static let home = GuildID(rawValue: 1)
    private static let other = GuildID(rawValue: 2)
    private static let general = ChannelID(rawValue: 10)
    private static let lounge = ChannelID(rawValue: 11)
    private static let help = ChannelID(rawValue: 12)
    private static let post = ChannelID(rawValue: 13)
    private static let secret = ChannelID(rawValue: 14)
    private static let info = ChannelID(rawValue: 15)
    private static let ada = ChannelID(rawValue: 20)
    private static let elsewhere = ChannelID(rawValue: 30)

    private var context: MentionContext {
        var context = MentionContext()
        context.currentGuildID = Self.home
        context.guildNames = [Self.home: "Home", Self.other: "Elsewhere"]
        func channel(
            _ name: String, _ guild: GuildID?, _ kind: ChannelKind,
            canView: Bool = true, isPost: Bool = false, parent: ChannelID? = nil
        ) -> LinkChannel {
            LinkChannel(
                name: name, guildID: guild, kind: kind,
                canView: canView, isPost: isPost, parentID: parent
            )
        }
        context.roles = [RoleID(rawValue: 77): MentionRole(name: "Verified")]
        context.channels = [
            Self.general: channel("general", Self.home, .text),
            Self.lounge: channel("Lounge", Self.home, .voice),
            Self.help: channel("help", Self.home, .forum),
            Self.post: channel("Why", Self.home, .publicThread, isPost: true, parent: Self.help),
            Self.secret: channel("mods", Self.home, .text, canView: false),
            Self.info: channel("Info", Self.home, .category),
            Self.ada: channel("ada", nil, .directMessage),
            Self.elsewhere: channel("general", Self.other, .text),
        ]
        return context
    }

    private func text(_ source: String) -> MessageText {
        MessageTextBuilder.build(
            document: MarkdownParser().parse(source), context: context, style: style
        )
    }

    private func symbols(_ text: MessageText) -> [String] {
        text.inlineSymbols.sorted { $0.key < $1.key }.map(\.value)
    }

    @Test("A channel in this server reads #channel, like a mention of it")
    func channelHere() throws {
        let url = "https://discord.com/channels/1/10"
        let chip = text(url)
        #expect(chip.attributed.string == "#general")
        #expect(chip.plates.count == 1)
        let link = try #require(chip.links.first)
        #expect(link.target == .channelLink(try #require(ChannelLink.parse(url)), url: url))
        #expect(link.range == NSRange(location: 0, length: chip.attributed.length))
    }

    @Test("One message in this server reads #channel › message")
    func messageHere() {
        let chip = text("https://discord.com/channels/1/10/99")
        #expect(chip.attributed.string == "#general \(Self.mark) \(Self.mark)")
        #expect(symbols(chip) == ["chevron.compact.right", "text.bubble.fill"])
        #expect(chip.links.count == 1)
    }

    @Test("A channel in another server is named after its server")
    func channelElsewhere() {
        let chip = text("https://discord.com/channels/2/30")
        #expect(chip.attributed.string == "Elsewhere \(Self.mark) #general")
    }

    @Test("A message in another server reads Server › message")
    func messageElsewhere() {
        let chip = text("https://discord.com/channels/2/30/99")
        #expect(chip.attributed.string == "Elsewhere \(Self.mark) \(Self.mark)")
        #expect(symbols(chip) == ["chevron.compact.right", "text.bubble.fill"])
    }

    /// `INVARIANTS.md` §5.5: a link into somebody's DM must not read like a
    /// mention of them. The chevron and the mark after it are the difference.
    @Test("A conversation reads @name › message, never like a mention")
    func conversation() {
        let chip = text("https://discord.com/channels/@me/20/5")
        #expect(chip.attributed.string == "@ada \(Self.mark) \(Self.mark)")
        #expect(chip.attributed.string != "@ada")
    }

    @Test("A post reads forum › post")
    func post() {
        let chip = text("https://discord.com/channels/1/12/threads/13/5")
        #expect(chip.attributed.string == "\(Self.mark) help \(Self.mark) \(Self.mark) Why")
        #expect(symbols(chip) == ["list.bullet.rectangle", "chevron.compact.right", "text.bubble"])
    }

    @Test("A channel of another kind leads with its own mark")
    func voiceChannel() {
        let chip = text("https://discord.com/channels/1/11")
        #expect(chip.attributed.string == "\(Self.mark) Lounge")
        #expect(symbols(chip) == ["speaker.wave.2.fill"])
    }

    /// Discord's "No Access", which is a statement and not a control.
    @Test("A channel the reader cannot see reads No Access, and is not a link")
    func noAccess() {
        let chip = text("https://discord.com/channels/1/14/5")
        #expect(chip.attributed.string == "\(Self.mark) No Access")
        #expect(symbols(chip) == ["lock.fill"])
        #expect(chip.links.isEmpty)
        #expect(chip.plates.count == 1)
    }

    @Test("A category is written as plain #name")
    func category() {
        let chip = text("https://discord.com/channels/1/15")
        #expect(chip.attributed.string == "#Info")
        #expect(chip.plates.isEmpty)
        #expect(chip.links.isEmpty)
    }

    @Test("A channel nobody here can name reads #unknown, and still opens its URL")
    func unknownChannel() throws {
        let url = "https://discord.com/channels/9/77/1"
        let chip = text(url)
        #expect(chip.attributed.string == "#unknown")
        let link = try #require(chip.links.first)
        #expect(link.target == .channelLink(try #require(ChannelLink.parse(url)), url: url))
    }

    @Test("An unknown channel in a server the account is in is named after it")
    func unknownChannelElsewhere() {
        #expect(text("https://discord.com/channels/2/77").attributed.string
            == "Elsewhere \(Self.mark) #unknown")
    }

    @Test("A <#id> mention is the same chip, pointing at the channel")
    func mention() throws {
        let chip = text("<#10>")
        #expect(chip.attributed.string == "#general")
        let link = try #require(chip.links.first)
        #expect(link.target == .channelLink(
            ChannelLink(guildID: Self.home, channelID: Self.general), url: nil
        ))
    }

    @Test("A mention of a channel nobody can name is no control")
    func unknownMention() {
        let chip = text("<#77>")
        #expect(chip.attributed.string == "#unknown")
        #expect(chip.links.isEmpty)
    }

    // MARK: Places in a server

    /// Alex's three, as Discord draws them: the place's glyph and its name.
    @Test("A place in a server is a chip with its glyph and its name", arguments: [
        ("<id:guide>", "signpost.right.fill", "Server Guide", StaticRoute.guide),
        ("<id:home>", "signpost.right.fill", "Server Guide", StaticRoute.home),
        ("<id:browse>", "square.grid.2x2", "Browse Channels", StaticRoute.browse),
        ("<id:customize>", "square.grid.2x2", "Channels & Roles", StaticRoute.customize),
    ])
    func place(source: String, symbol: String, title: String, route: StaticRoute) throws {
        let chip = text(source)
        #expect(chip.attributed.string == "\(Self.mark) \(title)")
        #expect(symbols(chip) == [symbol])
        #expect(chip.plates.count == 1)
        #expect(try #require(chip.links.first).target == .staticRoute(route, itemID: nil))
    }

    @Test("Linked roles name the role, when it is one the server has")
    func linkedRole() throws {
        let chip = text("<id:linked-roles:77>")
        #expect(chip.attributed.string == "\(Self.mark) Linked Roles \(Self.mark) Verified")
        #expect(symbols(chip) == ["link", "chevron.compact.right"])
        #expect(try #require(chip.links.first).target == .staticRoute(.linkedRoles, itemID: 77))
        #expect(text("<id:linked-roles:78>").attributed.string == "\(Self.mark) Linked Roles")
    }

    @Test("A look-alike host stays an ordinary URL")
    func lookAlike() throws {
        let url = "https://discord.com.evil.test/channels/1/10"
        let chip = text(url)
        #expect(chip.attributed.string == url)
        #expect(try #require(chip.links.first).target == .url(url))
    }
}
