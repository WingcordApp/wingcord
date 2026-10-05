import Foundation

/// Who may start a thread where, what kind it becomes, and what it is called
/// when nobody names it — Discord's rules (`406704` and `659617`).
public enum ThreadCreation {

    /// Discord's private-thread setting for a channel (`659617.k`): the
    /// "Private Thread" box offered and free, offered and fixed on, or not
    /// offered at all.
    public enum PrivateMode: Hashable, Sendable {
        case disabled
        case enabled
        /// The reader may only start private threads here, so the box is
        /// ticked and cannot be cleared.
        case privateOnly
    }

    /// Channels that hold threads (`95701`'s `wE`) — a forum's are its posts,
    /// started from its own New Post.
    public static func holdsThreads(_ kind: ChannelKind) -> Bool {
        kind == .text || kind == .announcement
    }

    /// Whether a public thread may be started here (`406704`'s `m`/`g`):
    /// Create Public Threads and Read Message History, and — from a message —
    /// one somebody wrote that has no thread yet.
    public static func canCreatePublic(in channel: Channel, permissions: Permissions, from message: Message? = nil) -> Bool {
        holdsThreads(channel.kind)
            && permissions.isSuperset(of: [.createPublicThreads, .readMessageHistory])
            && accepts(message)
    }

    /// Whether a private thread may be started here (`S`/`N`): Create Private
    /// Threads, in a text channel — never from a message.
    public static func canCreatePrivate(in channel: Channel, permissions: Permissions) -> Bool {
        channel.kind == .text && permissions.contains(.createPrivateThreads)
    }

    /// Discord's Create Thread on the composer's +: either kind will do.
    public static func canCreate(in channel: Channel, permissions: Permissions) -> Bool {
        canCreatePublic(in: channel, permissions: permissions)
            || canCreatePrivate(in: channel, permissions: permissions)
    }

    public static func privateMode(in channel: Channel, permissions: Permissions) -> PrivateMode {
        guard canCreatePrivate(in: channel, permissions: permissions) else { return .disabled }
        return canCreatePublic(in: channel, permissions: permissions) ? .enabled : .privateOnly
    }

    /// The thread kind Discord asks for (`H`): private when ticked, an
    /// announcement thread under an announcement channel, otherwise public.
    public static func kind(isPrivate: Bool, parent: Channel) -> ChannelKind {
        if isPrivate { return .privateThread }
        return parent.kind == .announcement ? .announcementThread : .publicThread
    }

    /// Discord's name for a thread nobody named (`659617.V`): the first
    /// embed's title cut at 40, the poll's question at 80, or the opening
    /// line's first words — whole words and the separators between them — up
    /// to 40, with "..." where it was cut.
    ///
    /// - Parameter text: the message as readable text — mentions already names.
    public static func defaultName(embedTitle: String?, pollQuestion: String?, text: String) -> String {
        if let embedTitle, !embedTitle.isEmpty { return cut(embedTitle, at: 40) }
        if let pollQuestion, !pollQuestion.isEmpty { return cut(pollQuestion, at: 80) }

        var line = String(text.split(separator: "\n", omittingEmptySubsequences: false).first ?? "")
        line = String(line.drop { $0 == " " || $0 == "#" || $0 == "-" })
        // Words and the separators between them, in turn, as Discord's loop
        // splits on runs of whitespace and punctuation.
        var pieces: [String] = []
        var current = ""
        var inSeparator = false
        for character in line {
            let isSeparator = character.isWhitespace || separators.contains(character)
            if isSeparator != inSeparator, !current.isEmpty {
                pieces.append(current)
                current = ""
            }
            inSeparator = isSeparator
            current.append(character)
        }
        if !current.isEmpty { pieces.append(current) }
        guard var name = pieces.first else { return "" }
        for piece in pieces.dropFirst() {
            guard name.count + piece.count <= 40 else { break }
            name += piece
        }
        return cut(name, at: 40)
    }

    /// Discord's `B`: the first `limit` characters and "...", when longer.
    private static func cut(_ string: String, at limit: Int) -> String {
        string.count > limit ? String(string.prefix(limit)) + "..." : string
    }

    private static let separators = Set("!@#$%^&*()_-+={}[]:\";'<>?,./")

    /// A thread starts only from something somebody wrote, and only once.
    private static func accepts(_ message: Message?) -> Bool {
        guard let message else { return true }
        return !message.flags.contains(.hasThread) && !message.isSystemEvent
    }
}
