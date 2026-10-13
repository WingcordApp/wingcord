import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// The menu bar's second-stage items (DESIGN-NOTES §10.1): Invite to, Manage
/// Server Notifications, Set Status… and Add a Server.
@Suite("Menu bar acts")
@MainActor
struct MenuBarActsTests {

    private let readerID = UserID(rawValue: 1)
    private let friendID = UserID(rawValue: 2)
    private let guildID = GuildID(rawValue: 100)
    private let talk = ChannelID(rawValue: 1001)
    private let dm = ChannelID(rawValue: 3001)

    private func model(everyone: Permissions) -> AppModel {
        let model = AppModel()
        model.currentUserID = readerID
        model.guilds = [guildID: Guild(id: guildID, name: "Server", ownerID: friendID)]
        let role = RoleID(rawValue: guildID.rawValue)
        model.roles[guildID] = [role: Role(id: role, name: "@everyone", position: 0, permissions: everyone)]
        model.members[guildID] = [readerID: Member(userID: readerID, roleIDs: [])]
        var index = ChannelIndex()
        index.replaceChannels([Channel(id: talk, kind: .text, guildID: guildID, name: "general")], inGuild: guildID)
        index.replacePrivateChannels([
            Channel(id: dm, kind: .directMessage, name: "", recipientIDs: [friendID]),
        ])
        model.channelIndex = index
        return model
    }

    private func selecting(_ channelID: ChannelID, everyone: Permissions) -> AppModel {
        let model = model(everyone: everyone)
        model.selectedChannelID = channelID
        model.refreshMenuContext()
        return model
    }

    @Test("Invite to Server and to Channel follow CREATE_INSTANT_INVITE")
    func serverInviteGate() {
        #expect(selecting(talk, everyone: [.viewChannel, .createInvite]).menuContext.canInvite)
        #expect(!selecting(talk, everyone: [.viewChannel]).menuContext.canInvite)
    }

    /// The person menu's list: servers the reader may invite to.
    @Test("In a direct message, Invite to lists the servers its person can join")
    func directMessageInviteList() {
        let model = selecting(dm, everyone: [.viewChannel, .createInvite])
        #expect(!model.menuContext.canInvite)
        #expect(model.menuContext.inviteGuilds.map(\.id) == [guildID])
        #expect(selecting(dm, everyone: [.viewChannel]).menuContext.inviteGuilds.isEmpty)
    }

    /// The menu bar has no control to point at; the server's name answers.
    @Test("A page of the server menu is asked for, and asking twice is asking twice")
    func serverMenuPage() {
        let model = selecting(talk, everyone: [.viewChannel, .createInvite])
        model.openServerMenuFromMenuBar(page: .invite, inviteChannelID: talk)
        let first = model.serverMenuPageRequest
        #expect(first?.guildID == guildID)
        #expect(first?.page == .invite)
        #expect(first?.inviteChannelID == talk)
        model.openServerMenuFromMenuBar(page: .invite, inviteChannelID: talk)
        #expect(model.serverMenuPageRequest != first)
    }

    @Test("Set Status… opens the reader's own main card on the editor")
    func setStatus() {
        let model = model(everyone: [])
        model.ownCardAnchor = CGRect(x: 10, y: 600, width: 200, height: 40)
        model.openOwnCard(on: .customStatus)
        let request = model.profileRequest
        #expect(request?.userID == readerID)
        #expect(request?.showsOwnActions == true)
        #expect(request?.showsMainProfile == true)
        #expect(request?.ownSurface == .customStatus)
        #expect(request?.anchor == model.ownCardAnchor)
    }

    /// Discord's `clone-channel`: Create Channel on the original's name, type
    /// and category, with its permissions, limit and bitrate to copy.
    @Test("Duplicate Channel opens Create Channel on the original")
    func duplicateChannel() {
        let model = model(everyone: [.viewChannel, .manageChannels])
        model.openChannelDuplication(of: talk)
        let request = model.channelCreation
        #expect(request?.guildID == guildID)
        #expect(request?.kind == .text)
        #expect(request?.duplicating?.id == talk)
        #expect(request?.duplicating?.name == "general")
    }

    /// Only this session's visits, so that Clear Recents visibly clears.
    @Test("Recents lists the session's visits, not the open channel, and clears")
    func recents() {
        let model = model(everyone: [.viewChannel])
        let other = ChannelID(rawValue: 1002)
        model.channelIndex.replaceChannels([
            Channel(id: talk, kind: .text, guildID: guildID, name: "general"),
            Channel(id: other, kind: .text, guildID: guildID, name: "random"),
        ], inGuild: guildID)
        model.recentChannelIDs = [talk, other]
        model.selectedChannelID = talk
        model.refreshMenuContext()
        #expect(model.menuContext.recentChannels.map(\.title) == ["random"])
        model.clearRecents()
        #expect(model.menuContext.recentChannels.isEmpty)
    }

    /// Discord's `288104`: a stage's levels are All Live Stages and Nothing,
    /// and a voice channel has none — in the channel's menu and the menu bar.
    @Test("A stage has its own notification levels, and a voice channel none")
    func stageLevels() {
        #expect(ChannelOptionsMenu.levels(for: .voice).isEmpty)
        #expect(ChannelOptionsMenu.levels(for: .stage) == [.onlyMentions, .nothing])
        #expect(ChannelOptionsMenu.levelTitle(.onlyMentions, kind: .stage, inCategory: false) == "All Live Stages")
        #expect(ChannelOptionsMenu.levelTitle(.onlyMentions, kind: .text, inCategory: false) == "Only @mentions")
        #expect(ChannelOptionsMenu.levelTitle(.inherit, kind: .stage, inCategory: true) == "Use Category Default")
    }

    @Test("Add a Server is Discord's ⇧⌘N and opens the join sheet")
    func addServer() {
        let model = model(everyone: [])
        AppShortcut.addServer.perform(in: model)
        #expect(model.joinServerSheet != nil)
        #expect(AppShortcut.addServer.defaultBinding.modifiers == [.command, .shift])
    }
}
