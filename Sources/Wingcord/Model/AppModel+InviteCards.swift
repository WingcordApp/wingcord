import Foundation
import WingcordCore

// MARK: - Invite cards

extension AppModel {

    /// Whether the reader is already where an invite leads: in the server, in
    /// the group, friends with the person. What turns Join into Go to Server,
    /// Join Group DM into Joined, and Add Friend into Send a Message.
    func isInviteSettled(_ card: InviteCard) -> Bool {
        // A voice card is settled when the reader is in its room: Open, not
        // Join Voice.
        if let channelID = voiceInviteChannel(of: card) {
            return currentUserID.flatMap { voiceStates[$0]?.channelID } == channelID
        }
        return switch card.kind {
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
        // Discord's voice card: Join Voice joins the call; Open, once in it,
        // goes to the channel.
        if let channelID = voiceInviteChannel(of: card) {
            if currentUserID.flatMap({ voiceStates[$0]?.channelID }) == channelID {
                openInviteChannel(channelID)
            } else {
                joinVoice(channelID)
            }
            return
        }
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

    /// The voice invite card's way in — its "Server / channel" line: the
    /// channel, without joining the call.
    func openInviteChannel(_ channelID: ChannelID) {
        guard let guildID = channelIndex.guildID(of: channelID), canOpen(channelID) else { return }
        selectGuild(guildID)
        selectChannel(channelID)
    }

    /// The voice channel a card is Discord's voice card for — one the reader
    /// can see. Nil for every other card, which keeps its own.
    func voiceInviteChannel(of card: InviteCard) -> ChannelID? {
        guard card.kind == .server, card.isVoiceChannel, let channelID = card.channelID,
              channelIndex[channelID] != nil, canOpen(channelID) else { return nil }
        return channelID
    }

    /// Who is in each room a voice invite leads to, refreshed when somebody
    /// comes or goes — and the cards laid out again only when one of those
    /// rooms changed. Free while no voice invite has resolved.
    func refreshVoiceInviteRosters() {
        var channels: Set<ChannelID> = []
        for lookup in inviteLookups.values {
            if case .resolved(let card) = lookup, card.isVoiceChannel, let channelID = card.channelID {
                channels.insert(channelID)
            }
        }
        guard !channels.isEmpty || !voiceInviteRoster.isEmpty else { return }
        var roster: [ChannelID: [UserID]] = [:]
        var streamers: Set<UserID> = []
        for channelID in channels {
            let states = voiceStates(in: channelID)
            roster[channelID] = states.map(\.userID)
            for state in states where state.isStreaming { streamers.insert(state.userID) }
        }
        guard roster != voiceInviteRoster || streamers != voiceInviteStreamers else { return }
        voiceInviteRoster = roster
        voiceInviteStreamers = streamers
        cardRevision &+= 1
    }

    /// The rooms the transcript's voice cards draw, by channel — only those
    /// the reader can see; the rest keep Discord's ordinary card.
    func voiceInviteStates() -> [ChannelID: VoiceInviteState] {
        guard !voiceInviteRoster.isEmpty else { return [:] }
        var states: [ChannelID: VoiceInviteState] = [:]
        for (channelID, people) in voiceInviteRoster {
            guard canOpen(channelID), let channel = channelIndex[channelID],
                  let guildID = channelIndex.guildID(of: channelID), let guild = guilds[guildID]
            else { continue }
            states[channelID] = VoiceInviteState(
                guildName: guild.name,
                channelName: channel.name,
                people: people.map { userID in
                    VoiceInviteState.Person(
                        id: userID,
                        name: voiceName(of: userID, inGuild: guildID),
                        avatarURL: users[userID].flatMap { avatarURL(for: $0, side: 64) },
                        isStreaming: voiceInviteStreamers.contains(userID)
                    )
                },
                asChannelRow: usesVoiceChannelRow(in: guildID)
            )
        }
        return states
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
