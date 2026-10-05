import Foundation
import WingcordCore
import WingcordNet

extension SessionController {
    /// Delete User's Message on an AutoMod alert. Discord then edits the alert
    /// to say who did it — which takes the button away and puts the mark up —
    /// and deletes the member's message; both arrive as events, so nothing
    /// here changes the store.
    func performAutoModAlertAction(
        _ action: AutoModExecutedAction.Kind,
        alert alertID: MessageID,
        in channelID: ChannelID,
        guildID: GuildID
    ) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await rest.performAutoModAlertAction(action, alert: alertID, in: channelID, guildID: guildID)
            } catch {
                Self.trace("automod alert action \(action) on \(alertID) failed: \(Self.describe(error))")
            }
        }
    }

    /// A mention raid's Remove Restrictions, after Discord's confirmation.
    func clearMentionRaid(in guildID: GuildID) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await rest.clearMentionRaid(in: guildID)
            } catch {
                Self.trace("clear mention raid in \(guildID) failed: \(Self.describe(error))")
            }
        }
    }
}
