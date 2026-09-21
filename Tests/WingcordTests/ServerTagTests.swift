import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// Wearing a server's tag.
///
/// **The eligibility list has no route behind it.** Discord's own client reads
/// `guild?.profile?.tag != null` over the guilds READY already delivered — this
/// client was not decoding those two fields, so there was nothing to choose
/// from and the picker could not be built. The write (`PUT /users/@me/clan`)
/// had been implemented and had no caller.
@MainActor
@Suite("Server tags")
struct ServerTagTests {

    private func guild(_ id: UInt64, _ name: String, tag: String?, badge: String? = nil) -> Guild {
        Guild(
            id: GuildID(rawValue: id),
            name: name,
            ownerID: UserID(rawValue: 1),
            tag: tag,
            tagBadgeHash: badge
        )
    }

    @Test("A server offers a tag when it HAS one, not when it is allowed one")
    func offersTag() {
        // `GUILD_TAGS` says a server may set a tag; it does not say one is set.
        // Gating on the feature would list empty rows.
        #expect(guild(1, "Aliu", tag: "ALIU").offersTag)
        #expect(!guild(2, "Plain", tag: nil).offersTag)
        #expect(!guild(3, "Empty", tag: "").offersTag)
    }

    @Test("The badge is addressed as a clan badge")
    func badgeURL() throws {
        let url = try #require(
            CDN.guildTagBadge(
                guildID: GuildID(rawValue: 943223926509699072),
                hash: "080677e9263e77e660ac14431a30a26a"
            )
        )
        // Captured verbatim off `edit profile endgame.har`.
        #expect(url.absoluteString.contains("/clan-badges/943223926509699072/"))
        #expect(url.absoluteString.contains("080677e9263e77e660ac14431a30a26a.png"))
    }

    @Test("Only tagged servers reach the picker, in name order")
    func eligibleGuilds() {
        let model = AppModel()
        model.guilds = [
            GuildID(rawValue: 3): guild(3, "Zeta", tag: "ZETA"),
            GuildID(rawValue: 1): guild(1, "Aliu", tag: "ALIU"),
            GuildID(rawValue: 2): guild(2, "No Tag Here", tag: nil),
        ]
        let offered = model.guilds.values
            .filter(\.offersTag)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        #expect(offered.map(\.name) == ["Aliu", "Zeta"])
    }
}
