import Foundation
import Testing
@testable import WingcordCore

/// A user arrives from four places and only one of them knows anything.
///
/// **The bug these exist for**: a profile card open on screen went blank the
/// moment a roster update or a message from that person landed, because the bare
/// record that arrived replaced the enriched one the profile route had fetched.
@Suite("User merging")
struct UserMergeTests {

    private func user(
        name: String = "ada",
        decoration: UserDecoration? = nil
    ) -> User {
        User(
            id: UserID(rawValue: 1),
            username: name,
            displayName: name,
            discriminator: "0",
            decoration: decoration
        )
    }

    /// What the profile route knows and nothing else does.
    private var rich: UserDecoration {
        UserDecoration(
            bannerHash: "banner",
            bio: "Chronic Cat Lover",
            themeColorValues: [0x11_22_33, 0x44_55_66],
            badges: [AccountBadge(id: "nitro", iconHash: "h", label: "Nitro")],
            pronouns: "she/her",
            connectedAccounts: [
                ConnectedAccount(id: "1", service: "github", name: "ada", isVerified: true),
            ],
            premiumTier: .nitro,
            mutualGuilds: [MutualGuild(id: GuildID(rawValue: 9), nickname: nil)]
        )
    }

    /// What a member-list op or a message author carries.
    private var bare: UserDecoration {
        UserDecoration(avatarDecorationHash: "ring", primaryGuildTag: "ACNH")
    }

    @Test("A bare record keeps everything the enriched one knew")
    func bareDoesNotWipe() {
        let merged = user(decoration: bare).merged(over: user(decoration: rich))
        let decoration = merged.decoration
        #expect(decoration?.bio == "Chronic Cat Lover")
        #expect(decoration?.bannerHash == "banner")
        #expect(decoration?.badges.count == 1)
        #expect(decoration?.connectedAccounts.count == 1)
        #expect(decoration?.premiumTier == .nitro)
        #expect(decoration?.mutualGuilds.count == 1)
        #expect(decoration?.themeColorValues?.count == 2)
        // And the new record's own facts still land.
        #expect(decoration?.avatarDecorationHash == "ring")
        #expect(decoration?.primaryGuildTag == "ACNH")
    }

    /// A record with no decoration at all — a plain message author — must not
    /// take the card down either.
    @Test("A record with no decoration keeps the existing one")
    func nilDecorationKeepsExisting() {
        let merged = user().merged(over: user(decoration: rich))
        #expect(merged.decoration?.bio == "Chronic Cat Lover")
    }

    /// Identity is the incoming record's: a rename has to take effect.
    @Test("A rename still lands")
    func identityComesFromTheIncomingRecord() {
        let merged = user(name: "ada-lovelace", decoration: bare)
            .merged(over: user(name: "ada", decoration: rich))
        #expect(merged.username == "ada-lovelace")
    }

    /// The richer record wins where it has something to say.
    @Test("An enriched record overwrites a bare one")
    func enrichedWins() {
        let merged = user(decoration: rich).merged(over: user(decoration: bare))
        #expect(merged.decoration?.bio == "Chronic Cat Lover")
        // And keeps what only the bare one knew.
        #expect(merged.decoration?.avatarDecorationHash == "ring")
    }

    /// Nothing to merge stays nothing — a user with no cosmetics costs no box.
    @Test("Two empty records stay empty")
    func emptyStaysEmpty() {
        #expect(user().merged(over: user()).decoration == nil)
    }

    @Test("Merging over nothing is the record itself")
    func mergingOverNothing() {
        #expect(user(decoration: rich).merged(over: nil).decoration?.bio == "Chronic Cat Lover")
    }

    /// A tag is one fact in three fields and they travel together — keeping an
    /// old guild id beside a new nil badge would draw half a mark.
    @Test("A tag's three fields move as one")
    func tagFieldsMoveTogether() {
        let existing = user(decoration: UserDecoration(
            primaryGuildTag: "OLD",
            primaryGuildBadgeHash: "oldhash",
            primaryGuildID: GuildID(rawValue: 7)
        ))
        let incoming = user(decoration: UserDecoration(
            primaryGuildTag: "NEW",
            primaryGuildBadgeHash: "newhash",
            primaryGuildID: GuildID(rawValue: 8)
        ))
        let merged = incoming.merged(over: existing).decoration
        #expect(merged?.primaryGuildTag == "NEW")
        #expect(merged?.primaryGuildBadgeHash == "newhash")
        #expect(merged?.primaryGuildID == GuildID(rawValue: 8))
    }
}
