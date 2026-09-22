import Foundation
import WingcordCore

// MARK: - Messaging permissions, in `PreloadedUserSettings`
//
// **Every field number here came out of Discord's own compiled descriptor**,
// lifted from the app bundle on 2026-09-22 — the method `HANDOFF.md` records,
// and the same one that settled `message_request_restricted_guild_ids`. The
// whole top level was read at once rather than field by field, which is what
// makes it worth writing down:
//
//     PreloadedUserSettings
//       1 versions            10 game_library      19 clips
//       2 inbox               11 status            20 for_later
//       3 guilds              12 localization      21 safety_settings
//       4 user_content        13 appearance        22 icymi_settings
//       5 voice_and_video     14 guild_folders     23 applications
//       6 text_and_images     15 favorites         24 ads
//       7 notifications       16 audio_context     25 in_app_feedback
//       8 privacy             17 communities       26 app_version
//       9 debug               18 broadcast
//
// `messaging permissions.har` then pinned the values: eighteen PATCHes with one
// control moved at a time, and the diffs land on exactly the fields below.
//
// **The most dangerous thing in this file is the ORDER inside a content
// filter.** `explicit_content_guilds` is field **1**, not 3 — so the page's
// three rows, read top to bottom, are fields 2, 3, 1. Getting that backwards
// blurs a reader's servers when they asked to blur strangers' direct messages,
// and nothing errors.

public enum MessagingPrivacyProto {

    enum Top {
        static let textAndImages = 6
        static let privacy = 8
    }

    /// `TextAndImagesSettings`, the fields this page touches.
    enum Text {
        /// `view_nsfw_guilds` — "age-restricted servers on iOS".
        static let viewNSFWGuilds = 20
        /// `view_nsfw_commands` — "age-restricted commands from apps in DMs".
        static let viewNSFWCommands = 23
        /// `dm_spam_filter_v2`. A **bare enum**, not a wrapper message: it is
        /// written as a varint on the wire where every neighbour here is a
        /// length-delimited `BoolValue`.
        static let spamFilter = 27
        static let explicitContent = 29
        static let goreContent = 32
        static let selfHarmContent = 35
    }

    /// The one field number a category is written to.
    static func field(for category: ContentFilterCategory) -> Int {
        switch category {
        case .explicit: Text.explicitContent
        case .gore: Text.goreContent
        case .selfHarm: Text.selfHarmContent
        }
    }

    /// The field inside a category's message. **1 is the server one.**
    static func field(for surface: ContentFilterSurface) -> Int {
        switch surface {
        case .serverChannels: 1
        case .friendDirectMessages: 2
        case .otherDirectMessages: 3
        }
    }

    /// `PrivacySettings`, beyond what `ActivityPrivacyProto` already reads.
    enum Privacy {
        /// `friend_source_flags` — a `UInt32Value` carrying the bitmask.
        static let friendSourceFlags = 11
        /// `default_message_request_restricted`.
        static let messageRequestRestricted = 17
        /// `allow_game_friend_dms_in_discord`.
        static let gameFriendDirectMessages = 26
        /// `default_guilds_restricted_v2`.
        static let guildsRestricted = 27
        /// `hide_friend_request_notes`.
        static let hideFriendRequestNotes = 33
    }

    // MARK: Reading

    /// Everything the page shows, out of a whole settings blob — and the two raw
    /// messages a write has to splice back into.
    ///
    /// **Both raws, because the page writes to both.** A content filter lives in
    /// `text_and_images` and a friend source in `privacy`, and a writer handed
    /// the wrong one would replace the other message with a single field.
    public static func decode(
        _ blob: Data
    ) -> (privacy: MessagingPrivacy, textRaw: Data?, privacyRaw: Data?) {
        var value = MessagingPrivacy()
        var textRaw: Data?
        var privacyRaw: Data?
        var reader = ProtobufReader(blob)
        while let field = reader.next() {
            switch field.number {
            case Top.textAndImages:
                guard let data = reader.data(for: field) else { break }
                textRaw = data
                decodeText(data, into: &value)
            case Top.privacy:
                guard let data = reader.data(for: field) else { break }
                privacyRaw = data
                decodePrivacy(data, into: &value)
            default:
                break
            }
        }
        return (value, textRaw, privacyRaw)
    }

    private static func decodeText(_ data: Data, into value: inout MessagingPrivacy) {
        var reader = ProtobufReader(data)
        while let field = reader.next() {
            switch field.number {
            case Text.viewNSFWGuilds:
                value.allowsAgeRestrictedGuilds = (reader.wrappedValue(for: field) ?? 0) != 0
            case Text.viewNSFWCommands:
                value.allowsAgeRestrictedCommands = (reader.wrappedValue(for: field) ?? 0) != 0
            case Text.spamFilter:
                value.spamFilter = DMSpamFilter(rawValue: field.value) ?? .unset
            case Text.explicitContent:
                value.explicit = decodeFilter(reader.reader(for: field))
            case Text.goreContent:
                value.gore = decodeFilter(reader.reader(for: field))
            case Text.selfHarmContent:
                value.selfHarm = decodeFilter(reader.reader(for: field))
            default:
                break
            }
        }
    }

    private static func decodeFilter(_ reader: ProtobufReader) -> ContentFilter {
        var reader = reader
        var filter = ContentFilter()
        while let field = reader.next() {
            guard let surface = ContentFilterSurface.allCases.first(
                where: { Self.field(for: $0) == field.number }
            ) else { continue }
            filter[surface] = ContentRedaction(rawValue: field.value) ?? .unset
        }
        return filter
    }

    private static func decodePrivacy(_ data: Data, into value: inout MessagingPrivacy) {
        var reader = ProtobufReader(data)
        while let field = reader.next() {
            switch field.number {
            case Privacy.friendSourceFlags:
                value.friendSources = FriendSourceFlags(
                    rawValue: reader.wrappedValue(for: field) ?? FriendSourceFlags.all.rawValue
                )
            // **Every one of these is a RESTRICTION on the wire**, so the value
            // the page shows is its negation. A client that read them straight
            // would open direct messages the reader had shut.
            case Privacy.messageRequestRestricted:
                value.filtersMessageRequestsByDefault =
                    (reader.wrappedValue(for: field) ?? 0) == 0
            case Privacy.guildsRestricted:
                value.allowsDirectMessagesByDefault = (reader.wrappedValue(for: field) ?? 0) == 0
            case Privacy.hideFriendRequestNotes:
                value.showsFriendRequestNotes = (reader.wrappedValue(for: field) ?? 0) == 0
            case Privacy.gameFriendDirectMessages:
                value.allowsGameFriendDirectMessages =
                    (reader.wrappedValue(for: field) ?? 1) != 0
            default:
                break
            }
        }
    }

    // MARK: Writing

    /// One control's worth of change.
    ///
    /// **A case per control rather than a whole-value save.** `INVARIANTS.md`
    /// §1: a page sends the fields it owns, and this page's controls are
    /// eighteen separate switches in Discord's own client, each of which sends
    /// exactly itself. Saving the whole value would send eleven fields on every
    /// toggle — and would send this client's *reading* of the four it inverts.
    public enum Change: Hashable, Sendable {
        case contentFilter(ContentFilterCategory, ContentFilterSurface, ContentRedaction)
        case ageRestrictedCommands(Bool)
        case ageRestrictedGuilds(Bool)
        case spamFilter(DMSpamFilter)
        case directMessagesByDefault(Bool)
        case messageRequestsByDefault(Bool)
        case friendSources(FriendSourceFlags)
        case friendRequestNotes(Bool)
        case gameFriendDirectMessages(Bool)

        /// Which of the two top-level messages it is spliced into.
        public var isTextAndImages: Bool {
            switch self {
            case .contentFilter, .ageRestrictedCommands, .ageRestrictedGuilds, .spamFilter:
                true
            default:
                false
            }
        }
    }

    /// The body of `PATCH /users/@me/settings-proto/1` for one change.
    ///
    /// - Parameter raw: the message being written into, exactly as it arrived.
    ///   **Required**, and it is the whole safety argument — see
    ///   `ActivityPrivacyProto.replacing`: every field that is not the one
    ///   changing is copied across as the bytes it came in as, unread, so the
    ///   ten things in `text_and_images` this client has never heard of survive
    ///   somebody blurring a picture.
    public static func patch(applying change: Change, to raw: Data) -> String {
        var inner = ProtobufWriter()
        let field: Int

        switch change {
        case .contentFilter(let category, let surface, let redaction):
            field = Self.field(for: category)
            // The category's OWN message is spliced too: the three surfaces are
            // three fields inside it, and rebuilding it from one would clear the
            // other two.
            let existing = message(field: field, in: raw) ?? Data()
            var value = ProtobufWriter()
            value.varint(field: Self.field(for: surface), redaction.rawValue)
            let merged = ActivityPrivacyProto.replacing(
                field: Self.field(for: surface),
                with: redaction == .unset ? nil : value.data,
                in: existing
            )
            inner.message(field: field, merged)

        case .ageRestrictedCommands(let allowed):
            field = Text.viewNSFWCommands
            inner.message(field: field, boolValue(allowed))
        case .ageRestrictedGuilds(let allowed):
            field = Text.viewNSFWGuilds
            inner.message(field: field, boolValue(allowed))
        case .spamFilter(let filter):
            field = Text.spamFilter
            inner.varint(field: field, filter.rawValue)

        case .directMessagesByDefault(let allowed):
            field = Privacy.guildsRestricted
            inner.message(field: field, boolValue(!allowed))
        case .messageRequestsByDefault(let filters):
            field = Privacy.messageRequestRestricted
            inner.message(field: field, boolValue(!filters))
        case .friendSources(let flags):
            field = Privacy.friendSourceFlags
            var value = ProtobufWriter()
            value.varint(field: 1, flags.rawValue)
            inner.message(field: field, value.data)
        case .friendRequestNotes(let shows):
            field = Privacy.hideFriendRequestNotes
            inner.message(field: field, boolValue(!shows))
        case .gameFriendDirectMessages(let allowed):
            field = Privacy.gameFriendDirectMessages
            inner.message(field: field, boolValue(allowed))
        }

        let merged = ActivityPrivacyProto.replacing(field: field, with: inner.data, in: raw)
        var outer = ProtobufWriter()
        outer.message(
            field: change.isTextAndImages ? Top.textAndImages : Top.privacy,
            merged
        )
        return outer.base64
    }

    /// One submessage's bytes, or nil where the field was never written.
    private static func message(field number: Int, in raw: Data) -> Data? {
        var reader = ProtobufReader(raw)
        while let field = reader.next() {
            guard field.number == number else { continue }
            return reader.data(for: field)
        }
        return nil
    }

    /// A `BoolValue`.
    ///
    /// **False is an EMPTY message, and that is not a trick — it is proto3.**
    /// A wrapper carrying the type's default writes no field at all, so the
    /// emptiness *is* the value. The capture shows exactly this: turning a
    /// switch off sends a zero-length submessage, and turning it on sends
    /// `{1: 1}`.
    private static func boolValue(_ value: Bool) -> Data {
        guard value else { return Data() }
        var writer = ProtobufWriter()
        writer.varint(field: 1, 1)
        return writer.data
    }
}
