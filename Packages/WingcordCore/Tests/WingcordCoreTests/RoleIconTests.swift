import CoreGraphics
import Foundation
import Testing
@testable import WingcordCore

/// Which role's icon is drawn beside a name.
///
/// **The same rule the colour follows, and it has to be**: a senior role with
/// no icon must not blank out a junior role's, or a server whose top role is
/// plain would show no icon on anybody.
@Suite("Role icons")
struct RoleIconTests {

    private func role(
        _ id: UInt64,
        _ name: String,
        position: Int,
        icon: String? = nil,
        emoji: String? = nil
    ) -> Role {
        Role(
            id: RoleID(rawValue: id),
            name: name,
            position: position,
            iconHash: icon,
            unicodeEmoji: emoji
        )
    }

    @Test("The highest role that HAS an icon wins, not the highest role")
    func highestWithAnIcon() {
        let plain = role(1, "Member", position: 50)
        let vip = role(2, "VIP", position: 10, icon: "abc")
        let roles = [plain.id: plain, vip.id: vip]
        #expect(RoleResolver.iconRole(of: [plain.id, vip.id], in: roles)?.id == vip.id)
    }

    @Test("Between two decorated roles, seniority decides")
    func seniorityDecides() {
        let lower = role(1, "Donator", position: 10, icon: "low")
        let higher = role(2, "Admin", position: 90, icon: "high")
        let roles = [lower.id: lower, higher.id: higher]
        #expect(
            RoleResolver.iconRole(of: [lower.id, higher.id], in: roles)?.iconHash == "high"
        )
    }

    @Test("A unicode emoji counts as an icon")
    func emojiCounts() {
        // Discord's role editor offers an uploaded image *or* an emoji, never
        // both, and either is drawn in the same square.
        let emoji = role(1, "Crown", position: 10, emoji: "👑")
        #expect(RoleResolver.iconRole(of: [emoji.id], in: [emoji.id: emoji])?.id == emoji.id)
    }

    @Test("A member with no decorated role gets none")
    func noneAtAll() {
        let plain = role(1, "Member", position: 10)
        #expect(RoleResolver.iconRole(of: [plain.id], in: [plain.id: plain]) == nil)
        // And a role id the guild does not have is not a crash.
        #expect(RoleResolver.iconRole(of: [RoleID(rawValue: 99)], in: [:]) == nil)
    }
}
