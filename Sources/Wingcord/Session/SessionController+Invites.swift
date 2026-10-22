import Foundation
import WingcordCore
import WingcordNet

// MARK: - Invites posted in messages

extension SessionController {

    /// Asks what every invite linked in these messages is — Discord's own
    /// request as a chat opens, once per code per session.
    ///
    /// **Once, and never again on a failure.** An expired invite is an answer
    /// (`InviteLookup.invalid`) and is kept; a network failure is logged and
    /// left unanswered, so the link stays a link rather than retrying on every
    /// page the channel loads.
    ///
    /// An invite that came back with an event not yet over is that event's
    /// card instead (`346542`'s `ly`), measured as the answer lands.
    func resolveInvites(in messages: [Message]) {
        for message in messages {
            for code in InviteCard.codes(in: message.content)
            where model.inviteLookups[code] == nil && inviteFetches.insert(code).inserted {
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        let lookup = try await rest.inviteCard(code)
                        model.inviteLookups[code] = lookup
                        // A voice invite draws its room from the first frame.
                        if case .resolved(let card) = lookup, card.isVoiceChannel {
                            model.refreshVoiceInviteRosters()
                        }
                        if case .resolved(let card) = lookup, let event = card.event, event.status.isLive {
                            resolveEventCard(EventCardKey(guildID: event.guildID, eventID: event.id, invite: code))
                        }
                        model.cardRevision &+= 1
                        if case .resolved(let card) = lookup, let profile = card.profile,
                           let guildID = card.guildID {
                            deriveBannerColor(
                                guildID: guildID,
                                iconHash: profile.iconHash ?? card.iconHash,
                                brandColor: profile.brandColorPrimary
                            )
                        }
                    } catch {
                        Self.trace("invite card \(code) failed: \(Self.describe(error))")
                    }
                }
            }
        }
    }

    /// Accepts a group conversation's invite or a friend link from its card,
    /// and — for a group — takes the reader into it, as Discord's accept does.
    ///
    /// **The conversation arrives over the socket**, as `CHANNEL_CREATE`, so it
    /// is opened once the store has it rather than on the 200.
    func acceptInviteWithoutGuild(_ code: String) {
        guard inviteCardJoins.insert(code).inserted else { return }
        Task { [weak self] in
            guard let self else { return }
            defer { inviteCardJoins.remove(code) }
            guard let sessionID = await socket?.currentSessionID else {
                model.reportActionFailure("Not connected. Try again in a moment.")
                return
            }
            do {
                guard let channelID = try await rest.acceptInviteWithoutGuild(code, sessionID: sessionID)
                else { return }
                for _ in 0..<10 where model.channelIndex[channelID] == nil {
                    try? await Task.sleep(for: .milliseconds(120))
                }
                if model.channelIndex[channelID] != nil { model.openDirectMessage(channelID) }
            } catch {
                Self.trace("invite accept \(code) failed: \(Self.describe(error))")
                model.reportActionFailure(Self.describe(error))
            }
        }
    }

    /// Reads a server card's banner colour out of its icon, where the server
    /// chose none — Discord's `aG`, the icon's first swatch. Serves the invite
    /// card and the server tag's card, which draw the same banner.
    ///
    /// Through the same palette table and the same quantiser a profile's
    /// colours come from, off the main actor, once per picture.
    func deriveBannerColor(guildID: GuildID, iconHash: String?, brandColor: UInt32?) {
        guard brandColor == nil,
              let iconHash, let url = GuildBannerArt.paletteURL(guildID: guildID, iconHash: iconHash),
              model.derivedPalettes[url] == nil,
              paletteFetches.insert(url).inserted
        else { return }
        Task { [weak self] in
            guard let self else { return }
            defer { paletteFetches.remove(url) }
            let key = ImageStore.Key(url: url, maximumPixelSize: 64)
            guard let image = await ImageStore.shared.image(for: key, bucket: .thumbnail) else { return }
            let palette = await Task.detached(priority: .utility) {
                ProfileThemePalette.derive(from: image)
            }.value
            guard !palette.isEmpty else { return }
            model.derivedPalettes[url] = palette
            model.cardRevision &+= 1
        }
    }
}
