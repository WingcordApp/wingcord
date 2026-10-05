import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// The Welcome Screen: when its settings row exists, what its greeting offers,
/// and when a new member is greeted with it.
@Suite("Welcome Screen")
@MainActor
struct WelcomeScreenTests {

    private let guildID = GuildID(rawValue: 1)
    private let open = ChannelID(rawValue: 10)
    private let hidden = ChannelID(rawValue: 11)

    private func settings(_ features: Set<String>) -> GuildSettings {
        GuildSettings(id: guildID, name: "Sailors", ownerID: UserID(rawValue: 9), features: features)
    }

    @Test("The row is offered only for a Community server with a screen and no Server Guide")
    func rowGate() {
        let row = ServerSettingsSection.welcomeScreen
        #expect(row.isAvailable(in: settings(["COMMUNITY"]), isOwner: false, hasWelcomeScreen: true))
        // No screen — Discord's `welcomeScreenEmpty`.
        #expect(!row.isAvailable(in: settings(["COMMUNITY"]), isOwner: false, hasWelcomeScreen: false))
        // The Server Guide replaced it.
        #expect(!row.isAvailable(
            in: settings(["COMMUNITY", "GUILD_SERVER_GUIDE"]), isOwner: false, hasWelcomeScreen: true
        ))
        #expect(!row.isAvailable(in: settings([]), isOwner: false, hasWelcomeScreen: true))
        // Manage Server, as Discord's `canManageGuild`.
        #expect(row.isReachable(with: .manageGuild))
        #expect(!row.isReachable(with: .viewAuditLog))
    }

    @Test("It sits after Server Insights, in the community group")
    func rowPlace() {
        let group = ServerSettingsSection.groups.first { $0.sections.contains(.welcomeScreen) }
        #expect(group?.sections == [.community, .onboarding, .insights, .welcomeScreen])
    }

    @Test("The greeting offers only channels the reader can open, with the server's own emoji")
    func greetingOptions() {
        let model = AppModel()
        let readerID = UserID(rawValue: 2)
        model.currentUserID = readerID
        model.guilds[guildID] = Guild(id: guildID, name: "Sailors", ownerID: UserID(rawValue: 9))
        let everyone = RoleID(rawValue: guildID.rawValue)
        model.roles[guildID] = [everyone: Role(id: everyone, name: "@everyone", position: 0, permissions: [.viewChannel])]
        model.members[guildID] = [readerID: Member(userID: readerID, roleIDs: [])]
        var index = ChannelIndex()
        index.replaceChannels([Channel(id: open, kind: .text, guildID: guildID, name: "general")], inGuild: guildID)
        model.channelIndex = index
        model.guildEmojis[guildID] = [EmojiRef(id: EmojiID(rawValue: 77), name: "boat", isAnimated: true)]

        let screen = WelcomeScreen(description: "A place for sailors", channels: [
            .init(channelID: open, description: "Say hi", emojiID: EmojiID(rawValue: 77), emojiName: "boat"),
            .init(channelID: hidden, description: "Gone"),
        ])
        let presentation = model.welcomeScreenPresentation(for: guildID, screen: screen)
        #expect(presentation.serverName == "Sailors")
        #expect(presentation.description == "A place for sailors")
        #expect(presentation.options.map(\.channelID) == [open])
        #expect(presentation.options.first?.channelName == "general")
        // The animation comes from the server's set, which the wire leaves out.
        #expect(presentation.options.first?.emoji?.isAnimated == true)
    }

    @Test("A new member is greeted unless Onboarding replaced the screen")
    func greetingGate() {
        let model = AppModel()
        let screen = WelcomeScreen(channels: [.init(channelID: open, description: "Say hi")])

        model.offerWelcomeScreen(screen, inGuild: guildID, features: ["COMMUNITY", "GUILD_ONBOARDING"])
        #expect(model.welcomeScreenNotice == nil)
        model.offerWelcomeScreen(WelcomeScreen(), inGuild: guildID, features: ["COMMUNITY"])
        #expect(model.welcomeScreenNotice == nil)
        model.offerWelcomeScreen(nil, inGuild: guildID, features: ["COMMUNITY"])
        #expect(model.welcomeScreenNotice == nil)

        model.offerWelcomeScreen(screen, inGuild: guildID, features: ["COMMUNITY"])
        #expect(model.welcomeScreenNotice == WelcomeScreenNotice(guildID: guildID, screen: screen))
    }

    @Test("An unicode emoji is drawn by name; a custom one unknown here is drawn still")
    func emojiResolution() {
        let unicode = WelcomeScreen.Channel(channelID: open, description: "Hi", emojiName: "👋")
        #expect(unicode.emoji(among: []) == EmojiRef(name: "👋"))
        let custom = WelcomeScreen.Channel(channelID: open, description: "Hi", emojiID: EmojiID(rawValue: 5), emojiName: "x")
        #expect(custom.emoji(among: []) == EmojiRef(id: EmojiID(rawValue: 5), name: "x", isAnimated: false))
        #expect(WelcomeScreen.Channel(channelID: open, description: "Hi").emoji(among: []) == nil)
    }
}
