import AppKit
import Foundation
import WingcordCore

extension AppModel {
    /// A control on a drawn card was pressed — AutoMod's alert or notice, a
    /// safety notice. See `DrawnCardAction`.
    ///
    /// - Parameters:
    ///   - messageID: the card's own message — for an alert, the alert.
    ///   - channelID: the channel the card is in.
    func performCardAction(
        _ action: DrawnCardAction,
        on messageID: MessageID,
        in channelID: ChannelID,
        anchor: CGRect
    ) {
        let guildID = channelIndex.guildID(of: channelID)
        switch action {
        case .person(let userID):
            openProfile(userID, anchor: anchor)
        case .moderate(let userID):
            // Discord's Actions opens the member's moderation menu; this
            // client's member menu is that menu.
            openUserMenu(for: userID, anchor: anchor, inGuild: guildID)
        case .jumpToSurrounding(let target):
            sessionController.jumpToSurrounding(messageID, in: target)
        case .deleteFlaggedMessage:
            guard let guildID, permissionGate.permissions(in: channelID).contains(.manageMessages) else { return }
            sessionController.performAutoModAlertAction(
                .deleteUserMessage, alert: messageID, in: channelID, guildID: guildID
            )
        case .openFlaggedMessage(let flagged, let target):
            sessionController.jumpToMessage(flagged, in: target)
        case .removeMentionRestrictions(let decisionID):
            // Discord's: a notice that names its decision, and Manage Server.
            guard let guildID, decisionID != nil,
                  permissionGate.permissions(inGuild: guildID).contains(.manageGuild)
            else { return }
            mentionRaidRemoval = guildID
        case .configureAutoMod:
            guard let guildID else { return }
            ServerSettingsWindow.open(guildID, section: .safety)
        case .accountStanding:
            SettingsWindow.open(.account)
        case .openURL(let url):
            openExternal(url)
        }
    }

    /// Remove Restrictions, confirmed.
    func confirmMentionRaidRemoval() {
        guard let guildID = mentionRaidRemoval else { return }
        mentionRaidRemoval = nil
        sessionController.clearMentionRaid(in: guildID)
    }

    /// Discord's sentence over the mark of what a moderator did (`nQ`): their
    /// nickname here or their handle, and how long ago. Nil where Discord
    /// draws no tooltip — somebody this client does not know, or an undone
    /// completion.
    func autoModActionSentence(_ action: AutoModExecutedAction, in channelID: ChannelID) -> String? {
        guard let user = users[action.actorID] else { return nil }
        let nickname = channelIndex.guildID(of: channelID)
            .flatMap { members[$0]?[action.actorID]?.nickname }
            .flatMap { $0.isEmpty ? nil : $0 }
        return action.sentence(actorName: nickname ?? user.handle)
    }
}
