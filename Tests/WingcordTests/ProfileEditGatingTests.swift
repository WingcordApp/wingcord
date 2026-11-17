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
        // The theme pair and the banner image are premium.
        #expect(!free.canEditThemeColors)
        #expect(!free.canEditBanner)
        // **Effects and frames are not**, whatever the published table says:
        // Discord's editor draws Change Effect and Change Frame for every
        // account, and locks a single item (`canWear`) — the gate that kept
        // Alex from wearing his own effect and frame (2026-10-26).
        #expect(free.canEditProfileEffect)
        #expect(free.canEditCurrentEffect)

        let paid = model(tier: .nitro).profileEditCapability(for: .account)
        #expect(paid.canEditThemeColors)
        #expect(paid.canEditBanner)
        #expect(paid.canEditProfileEffect)
    }

    /// `ANIMATED_AVATAR` is in Classic's row of Discord's perk table and
    /// `PROFILE_PREMIUM_FEATURES` is not — so Classic moves its avatar and keeps
    /// a still banner (if it may set one at all).
    @Test("Classic wears a moving avatar; only Nitro a moving banner")
    func movingPictures() {
        let expectations: [(PremiumTier, avatar: Bool, banner: Bool)] = [
            (.none, false, false), (.basic, false, false), (.classic, true, false), (.nitro, true, true),
        ]
        for (tier, avatar, banner) in expectations {
            let capability = model(tier: tier).profileEditCapability(for: .account)
            #expect(capability.canUseAnimatedAvatar == avatar, "\(tier) moving avatar")
            #expect(capability.canUseAnimatedBanner == banner, "\(tier) moving banner")
        }
    }

    /// Discord's lock: `!canUseCollectibles(user) && purchaseType ===
    /// PREMIUM_PURCHASE`. Everything else an account owns, it wears.
    @Test("Only an item claimed through Nitro locks, and only without it")
    func collectibleLock() {
        let claimed = OwnedCollectible(skuID: "1", name: "Claimed", kind: .profileEffect, asset: "a", isNitroExclusive: true)
        let bought = OwnedCollectible(skuID: "2", name: "Bought", kind: .profileFrame, asset: "b")
        for tier in [PremiumTier.none, .basic, .classic] {
            let capability = model(tier: tier).profileEditCapability(for: .account)
            #expect(!capability.canWear(claimed), "\(tier) may not wear a Nitro claim")
            #expect(capability.canWear(bought), "\(tier) wears what it bought")
        }
        let nitro = model(tier: .nitro).profileEditCapability(for: .account)
        #expect(nitro.canWear(claimed) && nitro.canWear(bought))
    }

    /// Discord opens its styles to every account and swaps Apply for a Nitro
    /// footer; here a pick is tried on — the card shows it, nothing is saved.
    @Test("A display name style is tried on without Nitro and saved with it")
    func nameStyleTryOn() throws {
        #expect(!model(tier: .none).profileEditCapability(for: .account).canApplyNameStyle)
        #expect(!model(tier: .classic).profileEditCapability(for: .account).canApplyNameStyle)
        #expect(model(tier: .nitro).profileEditCapability(for: .account).canApplyNameStyle)

        let demo = AppModel()
        DemoFixtures.populate(demo)
        let me = try #require(demo.currentUserID)
        let base = try #require(demo.profileEditBase(for: .account, userID: me))
        let editor = ProfileEditor(profile: base, widgets: [], scope: .account, accountName: base.displayName)
        editor.appliesNameStyle = false
        editor.displayNameStyle = DisplayNameStyle(font: .sakura, effect: .neon, colors: [0xFF0000])
        #expect(!editor.isDirty, "a try-on raises no save bar")
        editor.appliesNameStyle = true
        #expect(editor.isDirty)
    }

    /// Discord's Vice City campaign (docs/ACTIVITY-CARDS.md decision 4): the
    /// one style an account without Nitro can save, as the font alone.
    @Test("Without Nitro the Vice City font saves, as the font alone")
    func viceCityFontSavesWithoutNitro() throws {
        let demo = AppModel()
        DemoFixtures.populate(demo)
        let me = try #require(demo.currentUserID)
        let base = try #require(demo.profileEditBase(for: .account, userID: me))
        let editor = ProfileEditor(profile: base, widgets: [], scope: .account, accountName: base.displayName)
        editor.appliesNameStyle = false
        editor.allowsCampaignFont = true
        editor.displayNameStyle = DisplayNameStyle(font: .hexagon, effect: .neon, colors: [0xFF0000])
        #expect(editor.isDirty)
        #expect(editor.savedNameStyle == DisplayNameStyle(font: .hexagon, effect: .solid, colors: []))
        // Any other face stays a try-on.
        editor.displayNameStyle = DisplayNameStyle(font: .sakura, effect: .solid, colors: [])
        #expect(editor.savedNameStyle == base.displayNameStyle)
        // Outside the campaign, the font is a try-on like the rest.
        editor.allowsCampaignFont = false
        editor.displayNameStyle = DisplayNameStyle(font: .hexagon, effect: .solid, colors: [])
        #expect(editor.savedNameStyle == base.displayNameStyle)
    }

    @Test("One colour on a free account, the theme pair on Nitro")
    func colourGate() {
        let free = model(tier: .none).profileEditCapability(for: .account)
        #expect(!free.canEditCurrentTheme)
        #expect(free.canEditAccentColor)
        #expect(model(tier: .nitro).profileEditCapability(for: .account).canEditCurrentTheme)
    }

    /// Discord's own rule: a server's profile without Nitro is a nickname and
    /// pronouns, and every other control is locked.
    @Test("A server profile without Nitro is a nickname and pronouns")
    func serverProfileLock() {
        let free = model(tier: .none).profileEditCapability(for: .guild(guildID))
        #expect(free.cosmeticsLocked)
        #expect(!free.canEditCurrentBio)
        #expect(!free.canEditCurrentBanner)
        #expect(!free.canEditCurrentTheme)
        #expect(!free.canEditCurrentEffect)
        #expect(!free.canUseAnimatedAvatar && !free.canUseAnimatedBanner)
        #expect(!free.canApplyNameStyle)
        #expect(free.canEditGuildPronouns)
        // Classic's moving avatar is the account's; a server's is Nitro's.
        #expect(!model(tier: .classic).profileEditCapability(for: .guild(guildID)).canUseAnimatedAvatar)

        let paid = model(tier: .nitro).profileEditCapability(for: .guild(guildID))
        #expect(!paid.cosmeticsLocked)
        #expect(paid.canEditCurrentBio && paid.canEditCurrentBanner && paid.canEditCurrentTheme)
        #expect(paid.canUseAnimatedAvatar && paid.canUseAnimatedBanner)

        // The account's own profile is never "locked" — its gates are field
        // by field.
        #expect(!model(tier: .none).profileEditCapability(for: .account).cosmeticsLocked)
    }

    /// `MANAGE_NICKNAMES` covers everybody's nickname, the reader's own
    /// included — Discord's check takes either.
    @Test("Managing nicknames is enough to change one's own")
    func manageNicknamesIsEnough() {
        let model = model(tier: .none)
        let moderator = RoleID(rawValue: 20)
        model.guilds[guildID] = Guild(id: guildID, name: "Server", ownerID: UserID(rawValue: 99))
        model.roles[guildID] = [
            RoleID(rawValue: guildID.rawValue): Role(id: RoleID(rawValue: guildID.rawValue), name: "@everyone"),
            moderator: Role(id: moderator, name: "Mod", position: 1, permissions: [.manageNicknames]),
        ]
        model.members[guildID] = [readerID: Member(userID: readerID, roleIDs: [moderator])]
        #expect(model.profileEditCapability(for: .guild(guildID)).canEditNickname)
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
