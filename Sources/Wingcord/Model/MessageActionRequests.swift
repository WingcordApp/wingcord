import CoreGraphics
import Foundation
import WingcordCore
import WingcordNet

// MARK: - What a row asks the window to raise
//
// The transcript is a **drawn canvas**, so nothing in it can host a
// presentation — `INVARIANTS.md` §1. Every surface a message raises is
// therefore a value written here with the rect that summoned it, and a
// presenter at the window root anchors to that rect.
//
// Each is `Identifiable` on something that changes when the *subject* changes
// and not otherwise, so re-opening the same menu from the same row does not
// tear the presentation down and build it again.

/// The message menu, anchored to the pill's "more" button or to a right-click.
struct MessageMenuRequest: Identifiable, Hashable, Sendable {
    var messageID: MessageID
    var channelID: ChannelID
    /// In the SwiftUI root's space — see `NSView.anchorInHostingRoot`.
    var anchor: CGRect

    var id: UInt64 { messageID.rawValue }
}

/// The emoji picker, opened to react rather than to compose.
///
/// **A distinct request from the composer's picker**, because the two differ in
/// what a pick *does*: one types a token into a draft, the other posts a
/// reaction to a specific message. One request carrying a mode would be a
/// picker that has to remember which it is.
struct ReactionPickerRequest: Identifiable, Hashable, Sendable {
    var messageID: MessageID
    var channelID: ChannelID
    var anchor: CGRect

    var id: UInt64 { messageID.rawValue }
}

/// The forward sheet.
struct ForwardRequest: Identifiable, Hashable, Sendable {
    var messageID: MessageID
    var channelID: ChannelID

    var id: UInt64 { messageID.rawValue }
}

/// A delete waiting to be confirmed.
///
/// **The message's own words travel with the request**, not a pointer back into
/// the store: the confirmation quotes what is about to go, and the row can be
/// deleted by somebody else while the dialog is up.
struct DeleteMessageRequest: Identifiable, Hashable, Sendable {
    var messageID: MessageID
    var channelID: ChannelID
    var authorName: String
    var excerpt: String
    /// Whether the reader is deleting somebody else's — which is a different
    /// sentence and a different weight of decision.
    var isOwn: Bool

    var id: UInt64 { messageID.rawValue }
}

/// A report in progress.
struct ReportRequest: Identifiable, Hashable, Sendable {
    var subject: ReportSubject
    /// What the report is about, drawn at the top of every screen so the reader
    /// can see they are reporting the right thing.
    var preview: QuotedMessage

    var id: ReportSubject { subject }
}

/// One message, quoted: who wrote it, when, and a line of what it said.
///
/// **One value for both the report flow and the forward sheet**, because both
/// ask the same question — "is this the message you meant?" — and two nearly
/// identical previews is two places for the avatar's size to drift.
struct QuotedMessage: Hashable, Sendable {
    var authorName: String
    var avatarURL: URL?
    var monogram: String
    var timestamp: String?
    var excerpt: String
}

/// The actions offered for one person.
struct UserMenuRequest: Identifiable, Hashable, Sendable {
    var userID: UserID
    /// The server the person was clicked in, for the report's `guild_id` and
    /// for resolving a nickname. Nil in a direct message.
    var guildID: GuildID?
    var anchor: CGRect

    var id: UInt64 { userID.rawValue }
}

/// What the pointer is resting on in the transcript, and where.
///
/// **Written to the store rather than published through a closure**, for the
/// same reason every other canvas-raised surface is: the representable holds no
/// closure over the model, so two of them compare as values.
///
/// The rect is in the **scroll view's viewport**, not the window — the pill is
/// overlaid on the transcript's own frame and travels with it, and a hover is
/// cleared the moment a scroll starts, so a viewport-relative rect can never go
/// stale under it.
struct MessageHover: Hashable, Sendable {
    var messageID: MessageID
    var rowFrame: CGRect
}

/// A message being edited, and the text so far.
///
/// **Beside the draft rather than replacing it.** An edit borrows the composer;
/// it must not eat what the reader had already typed and not sent.
struct MessageEdit: Hashable, Sendable {
    var messageID: MessageID
    var text: String
    /// What it said when the edit began, so an unchanged commit can be
    /// recognised and skipped rather than sent as a no-op that stamps
    /// "(edited)" on somebody's message.
    var original: String

    var hasChanges: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            != original.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
