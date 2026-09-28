import Foundation
import WingcordCore

// MARK: - Profile links in messages

extension SessionController {

    /// Fetches the profile behind every profile link in these messages and
    /// measures its card — Discord's user profile embed, which asks for the
    /// profile as the message is drawn.
    ///
    /// **Once per person and server a session**, like an invite: the card is
    /// the app's own profile card, so it stays current from the store after
    /// that, and a card that later changes size says so itself — see
    /// `UserLinkCard`.
    func resolveUserCards(in messages: [Message], inGuild guildID: GuildID?) {
        for message in messages {
            for userID in UserLink.userIDs(in: message.content) {
                let key = UserCardKey(userID: userID, guildID: guildID)
                guard model.userCardSizes[key] == nil, userCardFetches.insert(key).inserted else { continue }
                Task { [weak self] in
                    guard let self else { return }
                    await fetchProfile(of: userID, inGuild: guildID)
                    // Nothing to draw a card from: the link stays a link.
                    guard model.users[userID] != nil else { return }
                    model.noteUserCardSize(UserCardHosts.measure(key, model: model), for: key)
                }
            }
        }
    }
}
