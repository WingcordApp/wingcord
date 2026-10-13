import Foundation
import Testing
import WingcordCore

@testable import Wingcord

// MARK: - A call has its own bar
//
// Discord's channel header has an empty toolbar case for voice and stage
// channels, and the call view puts back only its call items and Show Chat. This
// window's bar showed a text channel's — pins, the roster toggle, search — over
// a voice channel's "Join Voice". These pin the bar, the column beside the call
// and the menu bar's two items that had no business being on.
@MainActor
struct CallChromeTests {
    private let guildID = GuildID(rawValue: 1)
    private let textID = ChannelID(rawValue: 10)
    private let voiceID = ChannelID(rawValue: 20)
    private let stageID = ChannelID(rawValue: 30)

    private let readerID = UserID(rawValue: 7)

    /// The reader owns the server, so every permission resolves — which is what
    /// makes "no pins here" mean the kind and not a missing grant.
    private func model(selecting channelID: ChannelID) -> AppModel {
        let model = AppModel()
        model.currentUserID = readerID
        model.guilds = [guildID: Guild(id: guildID, name: "server", ownerID: readerID)]
        var index = ChannelIndex()
        index.replaceChannels([
            Channel(id: textID, kind: .text, guildID: guildID, name: "general", position: 0),
            Channel(id: voiceID, kind: .voice, guildID: guildID, name: "main-vc", position: 1),
            Channel(id: stageID, kind: .stage, guildID: guildID, name: "town-hall", position: 2),
        ], inGuild: guildID)
        model.channelIndex = index
        model.selectedGuildID = guildID
        model.selectedChannelID = channelID
        return model
    }

    @Test("A voice or stage channel's bar has the chat toggle and nothing of a text channel's")
    func callBarCarriesOnlyTheChat() {
        for channelID in [voiceID, stageID] {
            let chrome = model(selecting: channelID).channelChrome
            #expect(chrome.canShowVoiceChat)
            #expect(!chrome.canShowPins)
            #expect(!chrome.canShowMemberList)
            #expect(!chrome.canShowThreads)
            #expect(!chrome.canShowSummaries)
        }
        // The text channel beside it keeps both — the gate is the kind.
        let text = model(selecting: textID).channelChrome
        #expect(text.canShowMemberList)
        #expect(text.canShowPins)
    }

    @Test("A call offers no search")
    func callHasNoSearch() {
        #expect(model(selecting: voiceID).workspacePresentation.primary.isCall)
        #expect(model(selecting: stageID).workspacePresentation.primary.isCall)
        #expect(!model(selecting: textID).workspacePresentation.primary.isCall)
    }

    @Test("Beside a call is its chat or nothing, never the roster a text channel left on")
    func callColumnIsChatOrNothing() {
        let model = model(selecting: voiceID)
        model.isMemberListShown = true
        #expect(model.workspacePresentation.supplementary == nil)
        model.isVoiceChatShown = true
        #expect(model.workspacePresentation.supplementary == .voiceChat(voiceID))
    }

    @Test("The menu bar's Search Channel and Member List are off in a call")
    func menuItemsFollowTheBar() {
        let model = model(selecting: voiceID)
        model.connectionState = .ready
        model.refreshMenuContext()
        #expect(!AppShortcut.searchChannel.isAvailable(in: model))
        #expect(!AppShortcut.memberList.isAvailable(in: model))
        #expect(!AppShortcut.showPins.isAvailable(in: model))
        #expect(AppShortcut.voiceChat.isAvailable(in: model))
    }
}
