import Foundation

/// A member's own flags in a server — Discord's `GuildMemberFlags` (`340837`).
///
/// **The onboarding pair** is how Discord decides whether to put a server's
/// onboarding in front of somebody: raised on joining unless it is complete,
/// and on opening the server only while it is started and not complete. What
/// the reader answered is no guide — onboarding can be finished having chosen
/// nothing. **The rest are moderation's** — Verify Member's bypass bit and the
/// three AutoMod quarantine bits the Members page draws as a signal.
public struct MemberFlags: OptionSet, Hashable, Sendable, Codable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let didRejoin = MemberFlags(rawValue: 1 << 0)
    public static let completedOnboarding = MemberFlags(rawValue: 1 << 1)
    /// Set by a moderator's Verify Member, cleared by Unverify Member — the
    /// member skips the server's verification level.
    public static let bypassesVerification = MemberFlags(rawValue: 1 << 2)
    public static let startedOnboarding = MemberFlags(rawValue: 1 << 3)
    public static let isGuest = MemberFlags(rawValue: 1 << 4)
    /// AutoMod quarantined them for their name or server nickname.
    public static let quarantinedName = MemberFlags(rawValue: 1 << 7)
    /// AutoMod quarantined them for their bio.
    public static let quarantinedBio = MemberFlags(rawValue: 1 << 8)
    /// AutoMod quarantined them for the server tag they wear.
    public static let quarantinedServerTag = MemberFlags(rawValue: 1 << 10)

    /// Discord's "can't talk in server until they change their member name" —
    /// any of the three quarantine bits (`TR` over `340837`).
    public var isQuarantined: Bool {
        !isDisjoint(with: [.quarantinedName, .quarantinedBio, .quarantinedServerTag])
    }

    /// Started and never finished: the one state Discord raises onboarding in
    /// for somebody opening a server they are already in.
    public var isOnboardingUnfinished: Bool {
        contains(.startedOnboarding) && !contains(.completedOnboarding)
    }
}
