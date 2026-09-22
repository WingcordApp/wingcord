import AppKit
import Foundation
import WingcordCore
import WingcordNet

// MARK: - Linked roles
//
// Three fetches and one write, and the shape of the flow is the reason they are
// separate: the *configuration* is per server and cheap, the *eligibility* is
// per role and measured live, and the authorize URL is per platform and hands
// the reader to a browser this app never hears back from.

extension SessionController {

    /// Every linked role in a server, fetched once per session.
    ///
    /// **Guarded on the cache, and the cache holds the empty answer too.** Most
    /// servers have no linked roles, and an empty array is a real answer — a
    /// guard that only remembered non-empty ones would re-ask every time the
    /// menu opened on exactly the servers that have nothing to say.
    func loadLinkedRoles(inGuild guildID: GuildID) {
        guard model.linkedRoles[guildID] == nil, !linkedRolesInFlight.contains(guildID) else {
            return
        }
        linkedRolesInFlight.insert(guildID)
        Task { [weak self] in
            guard let self else { return }
            defer { linkedRolesInFlight.remove(guildID) }
            do {
                model.linkedRoles[guildID] = try await rest.linkedRoles(inGuild: guildID)
            } catch {
                // **Left unset rather than cached as empty.** A 403 on a server
                // the reader can still see is a transient answer, and writing
                // it in as "no linked roles" would hide the row until the app
                // restarted.
                Self.trace("linked roles \(guildID) failed: \(Self.describe(error))")
            }
        }
    }

    /// Measures one role's rules against this account.
    ///
    /// Re-run every time the role's page is opened, and again after the reader
    /// comes back from a browser: the whole point of the page is whether the
    /// requirements are met *now*, and the thing that changes them happens
    /// outside this app.
    func loadLinkedRoleEligibility(_ roleID: RoleID, inGuild guildID: GuildID) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let groups = try await rest.linkedRoleEligibility(roleID, inGuild: guildID)
                model.applyLinkedRoleEligibility(groups, for: roleID, inGuild: guildID)
            } catch {
                Self.trace("role eligibility \(roleID) failed: \(Self.describe(error))")
            }
        }
    }

    /// Sends the reader to the platform to link the account.
    ///
    /// **A browser, and there is nothing to come back to.** Discord's OAuth
    /// redirect lands on a `discord.com` page, not on a URL scheme this app
    /// registers — see `connectionAuthorizeURL`. So the account's own return to
    /// the window is the signal, and the caller re-measures then.
    func beginLinkedRoleConnection(type: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await rest.connectionAuthorizeURL(type: type)
                NSWorkspace.shared.open(url)
            } catch {
                Self.trace("authorize \(type) failed: \(Self.describe(error))")
            }
        }
    }

    /// Takes the role.
    ///
    /// Nothing is applied here: `GUILD_MEMBER_UPDATE` is what puts the role on,
    /// and it arrives for a grant made on any client. The eligibility is
    /// re-measured so the page stops offering a role the reader now holds.
    func assignLinkedRole(_ roleID: RoleID, inGuild guildID: GuildID) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await rest.assignLinkedRole(roleID, inGuild: guildID)
            } catch {
                Self.trace("assign role \(roleID) failed: \(Self.describe(error))")
            }
            loadLinkedRoleEligibility(roleID, inGuild: guildID)
        }
    }
}
