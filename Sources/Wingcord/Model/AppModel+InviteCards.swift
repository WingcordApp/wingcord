import Foundation
import WingcordCore

// MARK: - Invite cards

extension AppModel {

    /// Whether the reader is already where an invite leads: in the server, in
    /// the group, friends with the person. What turns Join into Go to Server,
    /// Join Group DM into Joined, and Add Friend into Send a Message.
    func isInviteSettled(_ card: InviteCard) -> Bool {
        switch card.kind {
        case .server: card.guildID.map { guilds[$0] != nil } ?? false
        case .groupDirectMessage: card.channelID.map { channelIndex[$0] != nil } ?? false
        case .friend: card.inviterID.map { relationship(with: $0) == .friend } ?? false
        }
    }

    /// An invite card's button, as Discord's embed does it.
    ///
    /// **Settled invites go somewhere and open ones are accepted from the card**
    /// — Discord's `acceptInviteAndTransitionToInviteChannel`, with the join
    /// sheet's own accept underneath, so a captcha, the rules gate and the
    /// onboarding questions behave exactly as they do from Add a Server.
    func openInvite(_ card: InviteCard) {
        switch card.kind {
        case .server:
            guard let guildID = card.guildID else { return }
            if guilds[guildID] != nil {
                selectGuild(guildID)
                if let channelID = card.channelID, canOpen(channelID) { selectChannel(channelID) }
            } else {
                sessionController.joinFromInviteCard(card)
            }
        case .groupDirectMessage:
            if let channelID = card.channelID, channelIndex[channelID] != nil {
                openDirectMessage(channelID)
            } else {
                sessionController.acceptInviteWithoutGuild(card.code)
            }
        case .friend:
            guard let inviterID = card.inviterID, inviterID != currentUserID else { return }
            // **Send a Message opens the conversation whether or not one exists
            // yet.** Discord's does nothing when there is no conversation to go
            // to, which is a button that looks live and is not.
            if relationship(with: inviterID) == .friend {
                sessionController.openConversation(with: inviterID)
            } else {
                sessionController.acceptInviteWithoutGuild(card.code)
            }
        }
    }

    /// Opens a profile card past its fold, or folds it again.
    func toggleInviteFold(_ fold: InviteCardFold) {
        if expandedInviteCards.remove(fold) == nil { expandedInviteCards.insert(fold) }
        cardRevision &+= 1
    }

    /// Something an invite card's button reads has moved — a server joined, a
    /// group entered, a friendship made. Only a transcript that is showing an
    /// invite card is asked to look again.
    func inviteSettlementChanged() {
        guard !inviteLookups.isEmpty else { return }
        cardRevision &+= 1
    }
}
