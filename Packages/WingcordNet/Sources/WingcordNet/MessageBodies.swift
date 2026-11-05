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
    /// A clip's fields — Discord writes them on the message's entry too
    /// (its `d` in the attachment module: `a.is_clip=!0, a.title=…`).
    var clip: ClipFields?
    var is_thumbnail: Bool?
    /// A voice note's two fields, from the same writer as the clip's.
    var duration_secs: Double?
    var waveform: String?

    init(_ attachment: UploadedAttachment) {
        duration_secs = attachment.voice?.durationSeconds
        waveform = attachment.voice?.waveform
        is_thumbnail = attachment.isThumbnail ? true : nil
        id = attachment.id
        filename = attachment.filename
        uploaded_filename = attachment.uploadedFilename
        description = attachment.altText
        original_content_type = attachment.originalContentType
        clip = attachment.clip.map(ClipFields.init)
    }

    enum CodingKeys: String, CodingKey {
        case id, filename, uploaded_filename, description, original_content_type, is_thumbnail
        case duration_secs, waveform
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(filename, forKey: .filename)
        try container.encode(uploaded_filename, forKey: .uploaded_filename)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(original_content_type, forKey: .original_content_type)
        try container.encodeIfPresent(is_thumbnail, forKey: .is_thumbnail)
        try container.encodeIfPresent(duration_secs, forKey: .duration_secs)
        try container.encodeIfPresent(waveform, forKey: .waveform)
        try clip?.encode(to: encoder)
    }
}

/// A clip's fields, flat beside a file's own — `is_clip`, `title`,
/// `application_id`, `clip_created_at`, `clip_participant_ids`,
/// `clip_events_timeline`, `duration_secs`. Discord's `getUploadPayload` and
/// its message-attachment writer put exactly these (web build 641803), and a
/// distributed clip's two more (Phase 7.3): `clip_remote_id`, the moment's
/// shared id, and `clip_sync_timestamp`.
struct ClipFields: Encodable {
    var is_clip = true
    var title: String?
    var application_id: String?
    var clip_created_at: String
    var clip_participant_ids: [String]
    var clip_events_timeline: [ClipTimelineEvent]?
    var duration_secs: Double?
    var clip_remote_id: String?
    var clip_sync_timestamp: String?

    init(_ clip: ClipUpload) {
        title = clip.title
        application_id = clip.applicationID.map(String.init)
        // JavaScript's `toISOString()`: milliseconds and a `Z`.
        clip_created_at = ISO8601DateFormatter.withFraction.string(from: clip.createdAt)
        clip_participant_ids = clip.participantIDs.map(String.init)
        // Discord leaves it out when there is nothing in it.
        clip_events_timeline = clip.timeline.isEmpty ? nil : clip.timeline
        duration_secs = clip.durationSeconds
        clip_remote_id = clip.remoteID
        clip_sync_timestamp = clip.syncTimestamp.map(ISO8601DateFormatter.withFraction.string(from:))
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
