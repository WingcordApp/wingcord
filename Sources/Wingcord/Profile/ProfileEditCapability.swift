import Foundation

/// What the reader is actually allowed to change, field by field.
///
/// **Every line here is documented rather than guessed**, off
/// `docs.discord.food`'s `PATCH /users/@me/profile` and
/// `PATCH /guilds/{id}/members/@me` parameter tables — each of which carries a
/// per-field "can only be changed for premium users" note and, for the
/// nickname, a permission column.
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
    /// Whether this server grants `CHANGE_NICKNAME`. Meaningless in the account
    /// scope, where there is no nickname.
    var canChangeNickname: Bool

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

    /// `theme_colors`, `banner` and `profile_effect_id` are all marked premium.
    var canEditThemeColors: Bool { customizesProfile }
    var canEditBanner: Bool { customizesProfile }
    var canEditProfileEffect: Bool { customizesProfile }

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

    /// What the rail's colour section is called, which is the reader-visible
    /// half of `canEditThemeColors`.
    var colourSectionTitle: String {
        customizesProfile ? "Theme & Banner" : "Banner Colour"
    }

    /// The line shown against a control the account cannot use.
    static let nitroNote = "Nitro only."
    static let nicknameNote = "This server doesn't let you change your nickname."
}
