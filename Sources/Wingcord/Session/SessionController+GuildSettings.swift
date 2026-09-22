import Foundation
import WingcordCore
import WingcordNet

// MARK: - The server menu's writes
//
// Every one of these is optimistic: the model has already moved the control and
// hands over what it was, so a refusal can put it back. That is the only shape
// that works for a menu — the reader is looking at the switch, and a round trip
// before it moves reads as a control that does not work.

extension SessionController {

    /// Sends one field of one server's settings.
    ///
    /// **The reply is taken as the truth, not merged.** Discord answers with the
    /// server's whole settings object, and for a mute that object carries the
    /// `end_time` it computed — which the optimistic value could only guess at,
    /// because the clock that matters is the server's.
    func writeGuildSettings(
        _ change: GuildUserSettingsChange,
        in guildID: GuildID,
        restoring previous: GuildUserSettings
    ) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let settings = try await rest.updateGuildUserSettings(
                    change, in: guildID, existing: previous
                )
                model.applyGuildUserSettings(settings)
            } catch {
                Self.trace("guild settings write failed: \(Self.describe(error))")
                model.applyGuildUserSettings(previous)
            }
        }
    }

    /// Makes the link the invite surface shows.
    ///
    /// **Thirty days, captured** — Discord's own invite modal sends
    /// `max_age: 2592000` and says "Your invite link expires in 30 days"
    /// underneath the field, which is the copy this client draws too.
    func mintInviteLink(for guildID: GuildID, channelID: ChannelID) {
        Task { [weak self] in
            guard let self else { return }
            do {
                model.serverInviteLinks[guildID] = try await rest.createInvite(in: channelID)
            } catch {
                // No link and no row: the surface keeps its spinner, which is
                // the honest state. A retry is re-opening it.
                Self.trace("invite link \(guildID) failed: \(Self.describe(error))")
            }
        }
    }

    /// Leaves a server, after the reader has confirmed it.
    ///
    /// **`lurking: false`**, because this row is only ever drawn for a server
    /// the account is a member of — a previewed one gets Discord's own two-row
    /// menu, whose Leave ends the lurk through `leavePreview`.
    ///
    /// Nothing is removed from the store here. `GUILD_DELETE` is what actually
    /// takes the server out of the rail, and it arrives for a leave made on any
    /// client; removing it optimistically as well would be two paths to one
    /// state, and the second one would have to guess at the selection.
    func leaveGuild(_ guildID: GuildID) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await rest.leaveGuild(guildID, lurking: false)
            } catch {
                // Nothing is put back: nothing was taken away. The rail still
                // holds the server, which is exactly what a failed leave means.
                Self.trace("leave guild \(guildID) failed: \(Self.describe(error))")
            }
        }
    }
}
