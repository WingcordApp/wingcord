import WingcordCore

/// Where a picked emoji goes — Discord's `EmojiIntention`, which its
/// `getEmojiUnavailableReason` reads to decide what is locked (its bundle,
/// read 2026-11-18).
///
/// **The picker used to take the composer's rule wherever it opened**, so a
/// reaction to somebody's status or activity — sent in a DM, where no server is
/// home — offered the selected server's emoji as usable, and Frequently Used
/// offered every server's (Alex, 2026-11-18: "a lot of react flyouts are still
/// not nitro gated properly").
enum EmojiDestination: Hashable, Sendable {
    /// A message typed in the composer over the selected channel (`CHAT`).
    /// Fake Nitro's links may stand in for what is locked.
    case composer
    /// Something posted in this channel that names the emoji itself — a
    /// reaction (`REACTION`) or a poll answer (`POLLS`): Discord's rule for the
    /// channel, which Fake Nitro cannot bend.
    case channel(ChannelID)
    /// Somewhere no server is home: a DM sent from somebody's status or
    /// activity, the reader's own status (`STATUS`), bio (`PROFILE`) or typing
    /// indicator (`TYPING_INDICATOR`). Every custom emoji needs Nitro there, an
    /// animated one Nitro's animated perk, a pack's emoji Nitro proper.
    case personal
    /// A server's own pages — its guide and onboarding (`COMMUNITY_CONTENT`):
    /// that server's emoji, animated included, with no Nitro asked, and no
    /// other server's at all.
    case community(GuildID)
    /// Unicode only (`GUILD_PROFILE`: a server's traits).
    case unicodeOnly
}

/// What a destination allows: the inputs the emoji catalog and the name rule
/// are built from (`AppModel.emojiAllowance(for:)`).
struct EmojiAllowance: Equatable, Sendable {
    /// The server whose emoji are at home here, if any.
    var home: GuildID?
    /// Whether another server's emoji may be used.
    var allowsExternal: Bool
    /// Whether an animated emoji may be used.
    var allowsAnimated: Bool
    /// Whether a Nitro Emoji Pack's emoji may be used.
    var packsUsable: Bool
    /// Whether other servers are offered at all — locked where not usable — or
    /// left out, as Discord leaves out what a destination never takes.
    var showsOtherServers = true
    /// Whether the reader's packs are offered.
    var showsPacks = true
    /// Whether any custom emoji is offered.
    var allowsCustom = true
}
