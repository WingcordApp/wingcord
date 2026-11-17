import Foundation

/// Discord's silent messages: a message that starts `@silent` is sent without
/// the prefix and with `SUPPRESS_NOTIFICATIONS`, so nobody gets a push or a
/// desktop notification for it — its module `677413`, word for word: the
/// prefix, then a space or the end (`^@silent(\s|$)`), and the rest trimmed.
public enum SilentMessage {
    public static let prefix = "@silent"

    /// Whether `content` asks to be silent, and what is sent if it does.
    public static func parse(_ content: String) -> (isSilent: Bool, content: String) {
        guard content.hasPrefix(prefix) else { return (false, content) }
        let rest = content.dropFirst(prefix.count)
        guard rest.isEmpty || rest.first?.isWhitespace == true else { return (false, content) }
        return (true, rest.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
