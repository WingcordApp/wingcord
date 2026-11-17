import Foundation
import WingcordCore

/// A message the reader sent that Discord has not answered — or refused.
///
/// **Beside the transcript, never in it.** `MessageBox.messages` is the server's
/// record: the read cursor, the window's paging anchors and its trims all read
/// it, and a local echo inside it would be acknowledged, paged from and trimmed
/// away. The rows are woven in where the transcript is built instead
/// (`AppModel.timelineRows`), which is Discord's own split — its local message
/// carries `state: SENDING`, and a send with files is not echoed as a message at
/// all: its files are a row of their own, drawn from the upload store.
struct OutgoingMessage: Identifiable, Equatable, Sendable {
    /// The nonce the send carries, minted as a snowflake when it was sent — so
    /// it is also the id the echo is drawn under, and it sorts and dates as now.
    let id: MessageID
    /// What the send asked for, kept so a refused one can be sent again.
    let request: Request
    /// The reader's own words, as the transcript draws them.
    let echo: Message
    var state: State
    /// The files going up with it. Empty for a plain send.
    let files: [PendingAttachment]
    /// How far the files have got, 0...1 — Discord draws one bar for the lot.
    var progress: Double = 0

    struct Request: Equatable, Sendable {
        var content: String
        var replyingTo: MessageID?
        /// Whether the reply pings its author — the reply bar's @ ON / OFF.
        var pingsRepliedAuthor = true
        var stickerIDs: [UInt64] = []
        /// A poll, which Discord posts with empty content.
        var poll: PollDraft?
        /// An invitation to listen along on the reader's Spotify, which is the
        /// whole message, as a poll is.
        var listenAlong: ListenAlongInvite?
        /// A reply at a moment of a clip — Discord's timeline comment.
        var mediaMention: MediaMention?
        /// A voice message: its one file is the message.
        var isVoiceMessage = false
        /// Sent with `@silent`: nobody is notified (`SilentMessage`).
        var isSilent = false

        /// What the message is besides its words, as the route takes it.
        var flags: MessageFlags {
            var flags: MessageFlags = []
            if isVoiceMessage { flags.insert(.isVoiceMessage) }
            if isSilent { flags.insert(.suppressNotifications) }
            return flags
        }
    }

    enum State: Hashable, Sendable {
        /// Still with Discord. Its words are drawn at half strength — Discord's
        /// `.isSending`.
        case sending
        /// Refused, or lost on the way. Drawn in the critical ink, with Resend
        /// and Delete in its menu.
        case failed
    }

    /// What a transcript keys its rows on: which sends are out, and how each
    /// stands. **Not the progress**, which moves a hundred times an upload and
    /// changes no row — it is painted, see `TimelineCanvasView`.
    struct Shape: Hashable, Sendable {
        var id: MessageID
        var state: State
    }

    var shape: Shape { Shape(id: id, state: state) }
    var nonce: String { String(id.rawValue) }
    /// **Not a voice note**, which draws as itself straight away: its echo has the file
    /// and the waveform, and what would otherwise be a card with a bar is the row it's
    /// about to become. It's a few kilobytes, so that's over before a bar would be read.
    var isUpload: Bool { !files.isEmpty && !request.isVoiceMessage }

    /// The line an upload's card is named by: the file, or how many — Discord's
    /// "Uploading 3 Files".
    var uploadTitle: String {
        files.count == 1 ? files[0].filename : "Uploading \(files.count) Files"
    }

    /// Everything going up, in Discord's own wording of a size.
    var uploadSize: Int { files.reduce(0) { $0 + $1.size } }
}

/// Clyde: the author Discord gives the explanations it writes on this machine.
///
/// **A user nobody can fetch.** Discord's local bot messages carry author `1`,
/// "Clyde", and a bundled picture rather than a CDN avatar, so the transcript
/// resolves this id itself rather than asking the store.
enum Clyde {
    static let userID = UserID(rawValue: 1)
    static let name = "Clyde"
    /// `BOT_AVATARS.clyde` in Discord's web client.
    static let avatarURL = URL(string: "https://discord.com/assets/9380e4b5bd8d267c.png")

    /// Discord's own explanation of a refused send, as a message only this
    /// session holds — `sendClydeError`'s, ephemeral, with Dismiss under it.
    static func notice(_ text: String, in channelID: ChannelID, id: MessageID) -> Message {
        Message(id: id, channelID: channelID, authorID: userID, content: text, flags: .ephemeral)
    }
}
