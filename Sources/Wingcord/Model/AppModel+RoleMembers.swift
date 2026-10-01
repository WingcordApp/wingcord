import CoreGraphics
import Foundation
import WingcordCore

/// A role mention that was clicked, and where.
struct RoleMembersRequest: Equatable {
    var guildID: GuildID
    var roleID: RoleID
    /// The mention's frame in window-root space, which the flyout opens beside.
    var anchor: CGRect
}

extension AppModel {

    /// Opens the holders of a role beside the mention that names it —
    /// Discord's role popout.
    ///
    /// The flyout draws what this session already knows at once, and the
    /// session asks for the rest: see `SessionController.loadRoleMembers`.
    func openRoleMembers(_ roleID: RoleID, inGuild guildID: GuildID, anchor: CGRect) {
        guard roles[guildID]?[roleID] != nil else { return }
        roleMembersRequest = RoleMembersRequest(guildID: guildID, roleID: roleID, anchor: anchor)
        sessionController.loadRoleMembers(roleID, in: guildID)
    }
}
