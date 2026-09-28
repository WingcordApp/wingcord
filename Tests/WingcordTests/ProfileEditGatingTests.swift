import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// Who may change what in the profile editor.
///
/// **Every expectation here is quoted from Discord's own parameter tables**, not
/// inferred from a screenshot: `PATCH /users/@me/profile` and
/// `PATCH /guilds/{id}/members/@me` each carry a per-field "can only be changed
/// for premium users" note, and the nickname carries a permission column.
///
/// The gate has to live in the client because the server answers far too late:
/// a refused field comes back `400 50035 · Invalid Form Body` *after* every
/// ungated edit in the same sheet has been written, so a reader who changed four
/// things sees one error and three silent successes.
@MainActor
@Suite("Profile edit gating")
struct ProfileEditGatingTests {

    private let readerID = UserID(rawValue: 1)
    private let guildID = GuildID(rawValue: 10)

    /// The tier on the ACCOUNT, and a user row that says nothing about it —
    /// the shape a real session has, where the row is rewritten by every route
    /// that carries a user object.
    private func model(tier: PremiumTier) -> AppModel {
        let model = AppModel()
        model.currentUserID = readerID
        model.entitlements = AccountEntitlements(premiumTier: tier)
        model.users = [readerID: User(id: readerID, username: "reader")]
        return model
    }

    @Test("Nitro proper, not merely a paid tier")
    func onlyNitroCounts() {
        // Nitro Basic is paid and carries none of these — Discord's own perk
        // table. A test for "has paid for something" offers Basic accounts
        // fields the server refuses.
        for tier in [PremiumTier.basic, .classic, .none] {
            let capability = model(tier: tier).profileEditCapability(for: .account)
            #expect(!capability.customizesProfile)
            #expect(!capability.customizesServerProfile)
        }
        let nitro = model(tier: .nitro).profileEditCapability(for: .guild(guildID))
        #expect(nitro.customizesProfile)
        #expect(nitro.customizesServerProfile)
    }

    @Test("A thin write of the reader's own row takes no perk away")
    func tierSurvivesTheUserRow() {
        // What a Nitro account saw: every gate read the tier off the reader's
        // row, and the row is replaced whole by the profile route and by
        // READY's arrays. The account's answer is the only one that counts.
        let model = model(tier: .nitro)
        model.users[readerID] = User(id: readerID, username: "reader")
        #expect(model.profileEditCapability(for: .guild(guildID)).canEditGuildAvatar)
        #expect(model.hasNitro)
    }

    @Test("The banner COLOUR is free; the theme and the banner image are not")
    func accountGates() {
        let free = model(tier: .none).profileEditCapability(for: .account)
        // `accent_color`, `bio` and `pronouns` carry no premium note at all.
        // **This is the one most easily got wrong**: the section is renamed on
        // Nitro, so the natural reading is that the whole thing unlocks. The
        // single colour was always free.
        #expect(free.canEditAccentColor)
        #expect(free.canEditBio)
        #expect(free.canEditPronouns)
        // `theme_colors`, `banner` and `profile_effect_id` are all marked
        // premium.
        #expect(!free.canEditThemeColors)
        #expect(!free.canEditBanner)
        #expect(!free.canEditProfileEffect)

        let paid = model(tier: .nitro).profileEditCapability(for: .account)
        #expect(paid.canEditThemeColors)
        #expect(paid.canEditBanner)
        #expect(paid.canEditProfileEffect)
    }

    @Test("The section's own name is the reader-visible half of the gate")
    func sectionTitle() {
        #expect(
            model(tier: .none).profileEditCapability(for: .account).colourSectionTitle
                == "Banner Colour"
        )
        #expect(
            model(tier: .nitro).profileEditCapability(for: .account).colourSectionTitle
                == "Theme & Banner"
        )
    }

    @Test("A per-server bio is premium where an account's is not")
    func guildBioIsGated() {
        let free = model(tier: .none).profileEditCapability(for: .guild(guildID))
        // The same control, gated in one scope and free in the other.
        #expect(free.canEditBio)
        #expect(!free.canEditGuildBio)
        // Per-server pronouns are the one per-server field with no premium note.
        #expect(free.canEditGuildPronouns)
        #expect(model(tier: .nitro).profileEditCapability(for: .guild(guildID)).canEditGuildBio)
    }

    @Test("The nickname is gated by a PERMISSION, and only inside a server")
    func nicknameGate() {
        // A server that withholds `CHANGE_NICKNAME` refuses the write — the one
        // profile field whose gate is not a subscription. With no roles and no
        // guild in the store the permission resolves empty, which is the
        // "server doesn't let you" case.
        let inGuild = model(tier: .nitro).profileEditCapability(for: .guild(guildID))
        #expect(!inGuild.canEditNickname)
        // Outside a server there is no nickname to permit, whatever the tier.
        let onAccount = model(tier: .nitro).profileEditCapability(for: .account)
        #expect(!onAccount.canChangeNickname)
    }
}
