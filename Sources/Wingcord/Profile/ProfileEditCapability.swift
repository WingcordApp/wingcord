import Foundation
import WingcordCore

/// What the reader is actually allowed to change, field by field.
///
/// **Every line here is read out of Discord's own client** (build 649389:
/// the perk table `836714`, the collectible checks `993408`, the editor's
/// sections `9ec6cb…`), and where the published parameter tables disagree the
/// client wins — they still mark `profile_effect_id` premium, while Discord's
/// editor offers effects and frames to every account and locks single items.
/// The nickname's permission column is the tables', and still holds.
///
/// It exists because the server answers far too late. Discord refuses a gated
/// field with `400 50035 · Invalid Form Body`, *after* every ungated edit in the
/// same sheet has already been written — so a reader who changed four things
/// sees one error, three silent successes and no way to tell which is which.
/// The editor has to know before it offers the control.
///
/// **The two scopes gate differently and the difference is not cosmetic.** An
/// account's banner colour is free and its *banner* is not; a server's nickname
/// is free of Nitro and gated on a permission the server may not grant. Reading
/// one table for both is how a control ends up disabled for everybody or for
/// nobody.
struct ProfileEditCapability: Equatable {

    /// Whether the subscription buys `profilePremiumFeatures` — the account's
    /// banner, theme colours and effect.
    ///
    /// **Nitro proper only**, from Discord's own perk table: Basic and Classic
    /// are paid tiers and carry none of these, so a test for "has paid for
    /// something" offers them fields the server refuses. Read off
    /// `AccountEntitlements`, never off the reader's user row.
    var customizesProfile: Bool
    /// Whether it buys `premiumGuildMemberProfile` — a per-server avatar,
    /// banner, bio and cosmetics. A perk of its own in Discord's table; the two
    /// happen to share a tier today.
    var customizesServerProfile: Bool
    /// Whether this server lets the reader rename themselves — `CHANGE_NICKNAME`
    /// or `MANAGE_NICKNAMES`, either one. Meaningless in the account scope,
    /// where there is no nickname.
    var canChangeNickname: Bool
    /// `ANIMATED_AVATAR` — a moving avatar on the account. **Nitro Classic
    /// carries it as well as Nitro**, so it is not `customizesProfile`.
    var animatesAvatar = false
    /// The `collectibles` perk — wearing what was claimed through Nitro.
    var wearsCollectibles = false
    /// Whether the profile being edited is a server's rather than the
    /// account's.
    var isServerScope = false

    // MARK: Account — `PATCH /users/@me/profile`

    /// `bio`, `pronouns` and `accent_color` carry no premium note at all.
    ///
    /// **So Banner Colour is NOT a Nitro field**, which is easy to get wrong:
    /// the section is called "Banner Colour" on a free account and "Theme &
    /// Banner" on a Nitro one, and the natural reading is that the whole section
    /// unlocks. It does not — the single colour was always free; Nitro adds the
    /// *second* colour and the banner image.
    var canEditAccentColor: Bool { true }
    var canEditBio: Bool { true }
    var canEditPronouns: Bool { true }

    /// The theme pair and the banner image are `PROFILE_PREMIUM_FEATURES`.
    var canEditThemeColors: Bool { customizesProfile }
    var canEditBanner: Bool { customizesProfile }
    /// **Open to every account.** Discord's editor draws Change Effect and
    /// Change Frame with no premium mark and no disabled state; what locks is
    /// a single item claimed through Nitro — `canWear` — never the section.
    /// Gating the section on Nitro is what kept Alex from wearing his own
    /// effect and frame (2026-10-26).
    var canEditProfileEffect: Bool { true }

    // MARK: Per-server — `PATCH /guilds/{id}/members/@me`

    /// The one field gated by a *permission* rather than by a subscription.
    var canEditNickname: Bool { canChangeNickname }
    /// Per-server pronouns carry no premium note, alone among the per-server
    /// fields.
    var canEditGuildPronouns: Bool { true }
    /// Everything else a server profile can carry is premium: `bio`, `banner`,
    /// `avatar`, `avatar_decoration_sku_id`, `collectibles` and the three
    /// `display_name_*` keys.
    var canEditGuildBio: Bool { customizesServerProfile }
    var canEditGuildAvatar: Bool { customizesServerProfile }
    var canEditGuildCosmetics: Bool { customizesServerProfile }

    // MARK: Whichever scope is open

    /// **A server's profile without Nitro is a nickname and pronouns**, and
    /// nothing else — Discord locks every other control there. This is the one
    /// question the rail asks of each cosmetic in a server.
    var cosmeticsLocked: Bool { isServerScope && !customizesServerProfile }

    /// The bio, in whichever profile is open.
    var canEditCurrentBio: Bool { isServerScope ? canEditGuildBio : canEditBio }
    /// The banner picture — Nitro in either scope.
    var canEditCurrentBanner: Bool { isServerScope ? customizesServerProfile : canEditBanner }
    /// The two-colour theme — Nitro in either scope; the one free colour is
    /// `canEditAccentColor`.
    var canEditCurrentTheme: Bool { isServerScope ? customizesServerProfile : canEditThemeColors }
    /// Effect and frame — every account on its own profile; Nitro in a
    /// server, where every cosmetic is.
    var canEditCurrentEffect: Bool { isServerScope ? customizesServerProfile : canEditProfileEffect }
    /// A moving avatar — Classic or Nitro on the account, Nitro in a server.
    var canUseAnimatedAvatar: Bool { isServerScope ? customizesServerProfile : animatesAvatar }
    /// A moving banner — wherever the banner itself may be set.
    var canUseAnimatedBanner: Bool { canEditCurrentBanner }
    /// Whether a display name style is SAVED. **Anybody may try one on** —
    /// Discord's styles modal opens for every account and swaps its Apply for
    /// a Nitro footer — so without the perk a pick shows on the card and the
    /// save leaves the name as it was (`ProfileEditor.appliesNameStyle`).
    var canApplyNameStyle: Bool { isServerScope ? customizesServerProfile : customizesProfile }

    /// Whether an owned decoration, effect, frame or nameplate may be worn.
    ///
    /// **Only an item claimed through Nitro locks**, and only without the
    /// perk: Discord's `!canUseCollectibles(user) && purchaseType ===
    /// PREMIUM_PURCHASE`. Bought, gifted, free, Orbs and quest items are worn
    /// by anybody who owns them.
    func canWear(_ item: OwnedCollectible) -> Bool { !item.isNitroExclusive || wearsCollectibles }

    /// The line shown against a control the account cannot use.
    static let nitroNote = "Nitro only."
    /// Under a locked server profile.
    static let serverProfileNote = "Without Nitro, a server profile is your nickname and pronouns."
    /// Against a moving picture the account cannot wear.
    static let animatedNote = "Moving pictures need Nitro. This one will be saved still."
    /// In the style flyout, for an account trying a style on.
    static let nameStyleNote = "Try any style on here. Saving keeps your name as it is — styles are a Nitro perk."
    static let nicknameNote = "This server doesn't let you change your nickname."
}
