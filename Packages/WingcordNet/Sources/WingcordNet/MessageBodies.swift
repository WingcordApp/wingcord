import Foundation
import WingcordCore

// The pieces of a message body that two routes send: `POST /channels/{id}/messages`
// and `POST /users/@me/scheduled-messages`, which takes the same message with a
// time beside it (Discord's `151282`).

/// A reply's reference. **`fail_if_not_exists` off**, so a reply to a message
/// deleted meanwhile still sends — a scheduled one may wait eight days.
struct ReplyBody: Encodable {
    var message_id: String
    var fail_if_not_exists = false

    init(_ messageID: MessageID) {
        message_id = messageID.description
    }
}

/// A reply that does not ping its author — Discord's mention toggle off
/// (`getSendMessageOptionsForReply`): every kind of mention parsed as usual,
/// only the replied-to author left out. Absent from a reply that pings, which
/// is how Discord sends one.
struct QuietReplyMentions: Encodable {
    var parse = ["users", "roles", "everyone"]
    var replied_user = false
}

/// A file already put up through `createUploadSlots` and `upload(_:to:)`.
///
/// **`uploaded_filename` is the object; `filename` is the label.** Sending the
/// reader's own name in the first field is the documented way to get a 500 out
/// of the route.
struct AttachmentBody: Encodable {
    var id: String
    var filename: String
    var uploaded_filename: String
    var description: String?
    var original_content_type: String?

    init(_ attachment: UploadedAttachment) {
        id = attachment.id
        filename = attachment.filename
        uploaded_filename = attachment.uploadedFilename
        description = attachment.altText
        original_content_type = attachment.originalContentType
    }
}

/// A poll, as Discord's `createPoll` writes it.
///
/// Only the answers with words, each its `poll_media`; a custom emoji goes as
/// its id with an empty name and a Unicode one as its sequence. `duration` is in
/// hours and `layout_type` is `DEFAULT`, the only layout the editor makes.
struct PollBody: Encodable {
    var question: Media
    var answers: [Answer]
    var allow_multiselect: Bool
    var duration: Int
    var layout_type = 1

    struct Media: Encodable {
        var text: String
        var emoji: Emoji?
    }

    struct Answer: Encodable {
        var poll_media: Media
    }

    struct Emoji: Encodable {
        var id: String?
        var name: String
    }

    init(_ draft: PollDraft) {
        question = Media(text: draft.question.trimmingCharacters(in: .whitespacesAndNewlines))
        answers = draft.postedAnswers.map { answer in
            Answer(poll_media: Media(
                text: answer.text.trimmingCharacters(in: .whitespacesAndNewlines),
                emoji: answer.emoji.map { emoji in
                    emoji.id.map { Emoji(id: $0.description, name: "") } ?? Emoji(name: emoji.name)
                }
            ))
        }
        allow_multiselect = draft.allowsMultiselect
        duration = draft.duration.rawValue
    }
}
