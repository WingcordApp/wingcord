import CoreGraphics
import WingcordCore

/// Where a message's words were when it was sent — the composer's text, read
/// from the field at the moment of the send.
///
/// **In window space, AppKit's own (y up)**, because the composer and the
/// transcript are two views that share nothing but the window: each converts
/// from it into its own space, at the moment it needs the answer.
struct SendLaunch: Equatable, Sendable {
    /// The first line's leading edge and baseline.
    var firstBaseline: CGPoint
    /// The field the words sat in, on the composer's bar — what a one-line
    /// message's bubble opens out of, as the sample's opens out of its field.
    var field: CGRect
    /// The size the words were set at in the field.
    var fontSize: CGFloat
    /// Whether the words fit on one line, which is when the bubble starts as
    /// wide as the field rather than as wide as itself.
    var isOneLine: Bool
}

/// A send the transcript flies from the composer into its place, once the
/// echo is laid out.
///
/// **A request on the store, like a jump**: the composer has no reference to
/// the transcript, and a transcript built later for the same channel must not
/// fly it again — the coordinator clears it once it is taken.
struct SendFlight: Equatable, Sendable {
    var channelID: ChannelID
    /// The send's nonce. It is the echo's id, and Discord's own copy carries it
    /// in its payload — so the flight follows the message when the one replaces
    /// the other, which is usually while it is still in the air.
    var nonce: MessageID
    var launch: SendLaunch
}
