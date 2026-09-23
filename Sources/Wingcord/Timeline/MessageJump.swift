import Foundation
import WingcordCore

/// A request to put one message on screen and mark it.
///
/// **A value on the store rather than a call into the timeline**, for the same
/// reason a profile request is: the thing that asks — a message link in a
/// transcript, a reply header, a search result later — has no reference to the
/// coordinator that owns the scroll view, and giving it one would mean a
/// coordinator reachable from every row.
///
/// `token` is what makes jumping to the *same* message twice work. Without it
/// the value is unchanged, `updateNSView` sees no difference, and the second
/// click does nothing at all — which reads as the link being broken rather than
/// as the app already being there.
struct MessageJump: Equatable, Sendable {
    var channelID: ChannelID
    var messageID: MessageID
    var token: UInt64
    /// Whether the landing message is lit. False where something else already
    /// marks the place — a topic's marker, above the message it opens on.
    var highlights = true

    /// How long the landing mark stays lit.
    ///
    /// One second, and it is self-initiated motion rather than a response — the
    /// reader did not ask for a flash, they asked to be taken somewhere, and the
    /// mark is how the app answers "here". `INVARIANTS.md` §3 exempts exactly
    /// this category from the 200 ms bar.
    static let highlightDuration: Duration = .seconds(1)
}

/// A request to put a transcript at its foot: the newest message, above the
/// composer.
///
/// `MessageJump`'s shape and for its reasons — a value on the store, because
/// what asks has no reference to the scroll view, and a token, because asking
/// twice is two requests. No message and no mark: the foot is not a message
/// to find, and landing there is its own answer.
struct PresentRequest: Equatable, Sendable {
    var channelID: ChannelID
    var token: UInt64
}
