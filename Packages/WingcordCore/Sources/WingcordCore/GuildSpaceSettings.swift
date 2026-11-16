import Foundation

/// A server's Server Hub switch and publishing state, as the guild object
/// carries them (`guild_space_settings`).
public struct GuildSpaceSettings: Hashable, Sendable, Codable {
    /// Nil where Discord sends no answer; `false` where the server switched the
    /// hub off in Server Settings › Engagement.
    public var isEnabled: Bool?
    public var publishStatus: PublishStatus

    /// A draft hub is seen by the people who can edit it, and nobody else.
    public enum PublishStatus: Int, Hashable, Sendable, Codable {
        case draft = 0
        case published = 1
    }

    public init(isEnabled: Bool?, publishStatus: PublishStatus) {
        self.isEnabled = isEnabled
        self.publishStatus = publishStatus
    }

    public var isPublished: Bool { publishStatus == .published }

    /// **Discord's rule** (`313627`'s `c`): never where the server switched it
    /// off; for an editor, otherwise always; for everyone else, only once it is
    /// on and published.
    public func isVisible(toEditor isEditor: Bool) -> Bool {
        guard isEnabled != false else { return false }
        return isEditor || (isEnabled == true && isPublished)
    }
}
