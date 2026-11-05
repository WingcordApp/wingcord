import Foundation
import WingcordCore

// MARK: - The sheet an invite link opens
//
// docs/FORUMS-INVITES.md D13–D15. Discord's rule (`539895`'s INVITE_MODAL_OPEN):
// **the sheet appears only when there's something to decide.** In the server
// already, a click goes there, and the sheet only appears for a role the invite
// grants that the reader doesn't hold. A group the reader is in opens. Everything
// else asks.

extension AppModel {

    /// Whether a link is an invite, opened here if it is. False leaves it to the
    /// browser.
    @discardableResult
    func openInviteLink(_ string: String) -> Bool {
        guard let key = InviteCard.key(ofLink: string) else { return false }
        openInvite(key: key)
        return true
    }

    /// Opens an invite by its key, from what's known or by asking.
    ///
    /// **A lookup the transcript already holds answers at once**: the link that
    /// was clicked usually has its card drawn right under it.
    func openInvite(key: String) {
        if let known = inviteLookups[key] {
            // A lookup still out for another link would land over this.
            sessionController.inviteSheetTask?.cancel()
            route(known, key: key)
        } else {
            sessionController.lookUpInviteForSheet(key)
        }
    }

    /// No Thanks, Escape, a click beside it, or a lookup given up on.
    func closeInviteSheet() {
        sessionController.inviteSheetTask?.cancel()
        inviteSheet = nil
    }

    /// A lookup, answered: goes there, or asks.
    func route(_ lookup: InviteLookup, key: String) {
        switch lookup {
        case .invalid:
            inviteSheet = InviteSheetState(key: key, phase: .invalid)
        case .resolved(let card):
            if goesStraightThere(card) {
                inviteSheet = nil
                goToInvite(card)
            } else {
                inviteSheet = freshSheet(for: card, key: key)
            }
        }
    }

    /// Whether the reader is already where the invite leads, with nothing to gain
    /// by accepting.
    func goesStraightThere(_ card: InviteCard) -> Bool {
        switch card.kind {
        case .server:
            guard let guildID = card.guildID, guilds[guildID] != nil else { return false }
            guard !card.grantedRoles.isEmpty, let currentUserID else { return true }
            let held = Set(members[guildID]?[currentUserID]?.roleIDs ?? [])
            return card.grantedRoles.allSatisfy { held.contains($0.id) }
        case .groupDirectMessage:
            return card.channelID.map { channelIndex[$0] != nil } ?? false
        case .friend:
            return card.inviterID.map { relationship(with: $0) == .friend } ?? false
        }
    }

    /// Discord's order: the invite's channel if the reader can see it, else the
    /// server. Never joins a voice room: a link is a place, not a call.
    private func goToInvite(_ card: InviteCard) {
        switch card.kind {
        case .server:
            guard let guildID = card.guildID else { return }
            selectGuild(guildID)
            if let channelID = card.channelID, canOpen(channelID) { selectChannel(channelID) }
        case .groupDirectMessage:
            if let channelID = card.channelID { openDirectMessage(channelID) }
        case .friend:
            if let inviterID = card.inviterID { sessionController.openConversation(with: inviterID) }
        }
    }

    /// The sheet at its defaults: Discord's `960736`.
    private func freshSheet(for card: InviteCard, key: String) -> InviteSheetState {
        var sheet = InviteSheetState(key: key, phase: .ready(card))
        sheet.allowsDirectMessages = messagingPrivacy.allowsDirectMessagesByDefault
        sheet.showsActivity = !activityPrivacy.sharingScope.restricts(memberCount: card.memberCount)
        return sheet
    }

    // MARK: What it draws

    /// Discord's `504394`, resolved.
    func inviteSheetPresentation(_ sheet: InviteSheetState) -> InviteSheetPresentation? {
        guard let card = sheet.card else { return nil }
        let account = currentUserID.flatMap { users[$0] }
        let art = demoInviteArt[card.code]
        let inviterName = card.inviterName ?? card.inviterUsername ?? ""
        let inviterFace = card.inviterID.flatMap { id in
            card.inviterAvatarHash.flatMap { CDN.avatar(userID: id, hash: $0, side: 80) }
        }

        var lead: String?
        var title = card.name
        var detail: AttributedString?
        var iconURL: URL?
        var monogram = String(card.name.prefix(2)).uppercased()
        var iconIsRound = false

        switch card.kind {
        case .server:
            lead = "You've been invited to join"
            iconURL = art?.icon ?? card.iconHash.flatMap { hash in
                card.guildID.flatMap { CDN.guildIcon(guildID: $0, hash: hash, side: 64) }
            }
            monogram = InvitePreviewMonogram.letters(of: card.name)
        case .groupDirectMessage:
            // A group with a name is named; one without is whoever sent it.
            let isNamed = !card.name.isEmpty
            lead = isNamed && !inviterName.isEmpty
                ? "\(inviterName) invited you to join"
                : "You've been invited to join a group DM by"
            title = isNamed ? card.name : inviterName
            iconURL = inviterFace
            iconIsRound = true
            monogram = InvitePreviewMonogram.letters(of: inviterName)
        case .friend:
            title = "\(inviterName) invited you to chat"
            var sentence = AttributedString("Accepting this invite will add ")
            var who = AttributedString(inviterName)
            who.inlinePresentationIntent = .stronglyEmphasized
            sentence.append(who)
            sentence.append(AttributedString(" as your friend on Discord."))
            detail = sentence
            iconURL = inviterFace
            iconIsRound = true
            monogram = InvitePreviewMonogram.letters(of: inviterName)
        }

        let isServer = card.kind == .server
        return InviteSheetPresentation(
            lead: lead,
            title: title,
            detail: detail,
            mark: card.mark,
            iconURL: iconURL,
            monogram: monogram,
            iconIsRound: iconIsRound,
            onlineCount: card.onlineCount,
            memberCount: card.kind == .friend ? nil : card.memberCount,
            roles: card.grantedRoles,
            splashURL: art?.splash ?? card.splashURL(width: 1040),
            offersSettings: isServer && !card.isGuestInvite,
            offersNickname: card.isNicknameChangeable,
            offersActivity: activityPrivacy.sharesCurrentGame,
            acceptsAsSomeone: card.kind != .friend,
            accountName: account?.preferredName ?? "",
            accountAvatarURL: account.flatMap { avatarURL(for: $0, side: 34) },
            accountMonogram: account?.monogram ?? "?",
            isAtServerLimit: isServer && isAtServerLimit,
            expiry: isServer ? card.expiryWords(now: .now) : nil
        )
    }

    /// Discord's `398884.Sn`: a hundred servers, and no increased cap. Tier 2
    /// Nitro's is two hundred.
    var isAtServerLimit: Bool {
        orderedGuildIDs.count >= 100 && entitlements.premiumTier != .nitro
    }

    /// Writes what the sheet's Server Settings chose, once the server is joined.
    /// Discord's `972387`: only what isn't already so.
    func applyInviteSettings(_ sheet: InviteSheetState, in guildID: GuildID) {
        let dmsOff = activityPrivacy.dmRestrictedGuildIDs.contains(guildID)
        if dmsOff == sheet.allowsDirectMessages {
            setGuildPrivacy(.directMessages, on: sheet.allowsDirectMessages, in: guildID)
        }
        if activityPrivacy.sharesCurrentGame {
            let activityOff = activityPrivacy.activityRestrictedGuildIDs.contains(guildID)
            if activityOff == sheet.showsActivity {
                setGuildPrivacy(.activitySharing, on: sheet.showsActivity, in: guildID)
            }
        }
    }
}

/// A server's or a person's two letters, as a server's monogram is built.
nonisolated enum InvitePreviewMonogram {
    static func letters(of name: String) -> String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" })
        let letters = words.prefix(2).compactMap(\.first)
        return letters.isEmpty ? "#" : String(letters).uppercased()
    }
}
