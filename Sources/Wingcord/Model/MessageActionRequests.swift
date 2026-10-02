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

/// Who reacted — Discord's reactors list, from the message menu or from a
/// chip's flyout.
struct ReactionsListRequest: Identifiable, Hashable, Sendable {
    var messageID: MessageID
    var channelID: ChannelID
    /// The entry it opens on — the chip a flyout was about — or nil for the
    /// largest, which is Discord's own default.
    var selection: ReactionListing.Key?

    var id: UInt64 { messageID.rawValue }
}

/// A select menu's options, open — Discord's dropdown, as a flyout off the
/// menu.
struct SelectMenuRequest: Identifiable, Hashable, Sendable {
    var messageID: MessageID
    var channelID: ChannelID
    var customID: String
    /// The menu's frame, in the window root's space.
    var anchor: CGRect
    /// What is chosen so far: the menu's own defaults to start with. Sent when
    /// the list closes, for a menu that takes more than one.
    var selection: Set<String>

    var id: String { "\(messageID.rawValue)/\(customID)" }
}

/// A form an application raised, and what the reader has put in it.
struct InteractionModalState: Equatable, Sendable {
    var modal: InteractionModal
    var answers: [String: InteractionModal.Answer]
    var isSubmitting = false
    /// Why the last send did not go, in words the reader can act on.
    var failure: String?
}

/// The forward sheet.
struct ForwardRequest: Identifiable, Hashable, Sendable {
    var messageID: MessageID
    var channelID: ChannelID

    var id: UInt64 { messageID.rawValue }
}

/// Discord's "Create a Poll", for one conversation.
struct PollEditorRequest: Identifiable, Hashable, Sendable {
    var channelID: ChannelID

    var id: ChannelID { channelID }
}

/// The Share Profile sheet — Discord's forward modal with a person in it.
struct ShareProfileRequest: Identifiable, Hashable, Sendable {
    var userID: UserID

    var id: UInt64 { userID.rawValue }

    /// What is sent: Discord's profile link (`f.A` in its share module).
    var link: String { "https://discord.com/users/\(userID.rawValue)" }
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
    var preview: ReportPreview

    var id: ReportSubject { subject }
}

/// What the sheet shows above the questions.
///
/// **A widget is redrawn, not excerpted.** A message and a person both reduce to
/// a line of text under a name, and that is enough to recognise them. A board
/// tile does not: its content is a picture, a grid of numbers or a list of game
/// covers, and one line of it would leave the reader confirming a report against
/// something they cannot identify. So the tile is drawn again, as itself.
enum ReportPreview: Hashable, Sendable {
    case quoted(QuotedMessage)
    case widget(BoardTile)
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

/// A conversation's own menu, and where to hang it.
///
/// **The channel is the subject, not the person.** Half of what this menu
/// offers is about the conversation — pin it, mute it, mark it read, close it —
/// and the other half is about whoever is in it. A group direct message has the
/// first half and no second half at all, which is exactly why the subject is
/// the channel and the person is an optional beside it.
struct DirectMessageMenuRequest: Identifiable, Hashable, Sendable {
    var channelID: ChannelID
    /// The other person, for a one-to-one conversation. Nil for a group, which
    /// has several and therefore none.
    var userID: UserID?
    var anchor: CGRect

    var id: UInt64 { channelID.rawValue }
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

/// A reaction chip under the pointer, and where it is in the transcript's clip
/// view — the space its tooltip is laid out in, for the reason
/// `MessageHover.rowFrame` is.
struct ReactionHover: Hashable, Sendable {
    var messageID: MessageID
    var emoji: EmojiRef
    var kind: ReactionKind
    var chipFrame: CGRect
}

/// A server's mark under the pointer on an invite card, and where it is in the
/// transcript's clip view — the space its flyout is laid out in, for the
/// reason `ReactionHover.chipFrame` is.
struct GuildMarkHover: Hashable, Sendable {
    var mark: GuildMark
    var frame: CGRect
}

/// One chip's reactors, as the tooltip asks for them.
struct ReactorKey: Hashable, Sendable {
    var messageID: MessageID
    var emoji: ReactionEmojiKey
    var kind: ReactionKind
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
