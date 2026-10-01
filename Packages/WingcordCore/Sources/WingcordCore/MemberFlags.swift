import Foundation

/// A member's own flags in a server — Discord's `GuildMemberFlags` (`340837`).
///
/// **Only the onboarding pair is read.** They are how Discord decides whether
/// to put a server's onboarding in front of somebody: raised on joining unless
/// it is complete, and on opening the server only while it is started and not
/// complete. What the reader answered is no guide — onboarding can be finished
/// having chosen nothing.
public struct MemberFlags: OptionSet, Hashable, Sendable, Codable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let completedOnboarding = MemberFlags(rawValue: 1 << 1)
    public static let startedOnboarding = MemberFlags(rawValue: 1 << 3)

    /// Started and never finished: the one state Discord raises onboarding in
    /// for somebody opening a server they are already in.
    public var isOnboardingUnfinished: Bool {
        contains(.startedOnboarding) && !contains(.completedOnboarding)
    }
}
