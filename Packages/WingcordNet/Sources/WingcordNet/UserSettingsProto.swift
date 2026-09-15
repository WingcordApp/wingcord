import Foundation
import WingcordCore

/// Discord's `PreloadedUserSettings`, as far as this client needs it.
///
/// **Every field number here was read off a live READY, not recalled.** A
/// protobuf parsed with the wrong numbering does not fail — it yields plausible
/// nonsense — so the blob was captured, walked by wire format alone, and the
/// numbers taken from what the account actually sent. Captured 2026-08-26 from
/// an account with 97 guilds; the shape below reproduced its six real folder
/// names, their colours, and a `guild_positions` list of exactly 97 entries.
///
/// ```
/// PreloadedUserSettings {
///   StatusSettings status  = 11 { StringValue status = 1 }
///   GuildFolders  folders  = 14 {
///     repeated GuildFolder folders   = 1 {
///       repeated fixed64 guild_ids = 1   // packed
///       Int64Value       id        = 2
///       StringValue      name      = 3
///       UInt64Value      color     = 4
///     }
///     repeated fixed64 guild_positions = 2   // packed
///   }
/// }
/// ```
///
/// Unknown fields are skipped, and a malformed blob yields empty settings rather
/// than throwing: Discord adds to this message continually, and the failure this
/// must never have is "one unrecognised byte and the rail is empty".
enum UserSettingsProto {

    private enum Field {
        /// `InboxSettings inbox = 2`.
        ///
        /// **Walked out of a capture, like every other number here.**
        /// `inbox.har` holds a `PATCH /users/@me/settings-proto/1` whose body is
        /// `{"settings":"EgQIBxAB"}` — six bytes, `12 04 08 07 10 01`: field 2,
        /// length 4, containing field 1 = 7 and field 2 = 1. The PATCH was sent
        /// while the Scheduled tab was open, and `SCHEDULED` is 7 in Discord's
        /// own `InboxTab` enum. That is the whole derivation, and it pins both
        /// the outer field number and the inner one.
        static let inbox = 2
        static let status = 11
        static let guildFolders = 14
    }

    private enum InboxField {
        static let currentTab = 1
        /// `viewed_tutorial`. Decoded by nothing — this client has no inbox
        /// tutorial to suppress — but **written back** as `true`, because the
        /// PATCH is a partial merge of the `inbox` message and sending
        /// `current_tab` alone would leave Discord's own clients showing the
        /// tutorial again on an account that has already dismissed it.
        static let viewedTutorial = 2
    }

    private enum MapEntryField {
        static let key = 1
        static let value = 2
    }

    private enum StatusField {
        static let status = 1
    }

    private enum FoldersField {
        static let folders = 1
        static let guildPositions = 2
    }

    private enum FolderField {
        static let guildIDs = 1
        static let id = 2
        static let name = 3
        static let color = 4
    }

    /// Decodes the base64 blob READY carries.
    static func decode(base64: String) -> ClientSettings? {
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else {
            return nil
        }
        return decode(data)
    }

    static func decode(_ data: Data) -> ClientSettings {
        var status: PresenceStatus = .online
        var folders: [GuildFolder] = []
        var guildPositions: [GuildID] = []
        var inboxTab: InboxTab = .fallback

        var reader = ProtobufReader(data)
        while let field = reader.next() {
            switch field.number {
            case Field.inbox:
                var inner = reader.reader(for: field)
                while let entry = inner.next() {
                    // **A bare varint, not a wrapped one**, and the guard on the
                    // wire type is what says so. The folder fields below are
                    // `Int64Value`/`StringValue` wrappers — a nested message
                    // with the value at field 1 — and `current_tab` is a plain
                    // enum written straight, which the capture's `08 07` shows.
                    // Reading it through `wrappedValue` would find no
                    // submessage and silently yield nothing, which is the
                    // failure this whole file warns about: plausible nonsense
                    // rather than an error.
                    guard entry.number == InboxField.currentTab, entry.wireType == 0 else {
                        continue
                    }
                    inboxTab = InboxTab.decoded(rawValue: Int(entry.value))
                }

            case Field.status:
                var inner = reader.reader(for: field)
                while let entry = inner.next() {
                    guard entry.number == StatusField.status else { continue }
                    if let raw = inner.wrappedString(for: entry) {
                        status = PresenceStatus(rawValue: raw) ?? .online
                    }
                }

            case Field.guildFolders:
                var inner = reader.reader(for: field)
                while let entry = inner.next() {
                    switch entry.number {
                    case FoldersField.folders:
                        if let folder = decodeFolder(inner.reader(for: entry)) {
                            folders.append(folder)
                        }
                    case FoldersField.guildPositions:
                        guildPositions = inner.packedFixed64(for: entry)
                            .map { GuildID(rawValue: $0) }
                    default:
                        break
                    }
                }

            default:
                break
            }
        }

        // **A second pass, deliberately.** Activity privacy is two sub-messages
        // this walk does not otherwise open, and its decoder has to keep their
        // raw bytes as well as their values — see `ActivityPrivacyProto`. Two
        // passes over a blob this size is microseconds, and one pass that tried
        // to do both would put the splice's safety argument in the middle of the
        // folder decode.
        let privacy = ActivityPrivacyProto.decode(data)
        return ClientSettings(
            folders: folders,
            guildPositions: guildPositions,
            status: status,
            customStatus: nil,
            inboxTab: inboxTab,
            activityPrivacy: privacy.privacy,
            privacyRaw: privacy.raw,
            statusRaw: privacy.statusRaw
        )
    }

    /// The body of `PATCH /users/@me/settings-proto/1` for one inbox tab.
    ///
    /// **A partial message, and that is the only thing that makes this safe.**
    /// The route merges rather than replaces — proved by the capture, whose
    /// whole body is six bytes against a stored settings blob of eight thousand
    /// — so nothing here has to serialise the hundreds of fields this client
    /// cannot read. A writer that rebuilt the message from what it understood
    /// would delete somebody's folders, their GIF favourites and their
    /// notification overrides. See `ProtobufWriter`.
    ///
    /// Reproduces `EgQIBxAB` exactly for `.scheduled`, which is what
    /// `InboxSettingsProtoTests` pins it against.
    static func encodeInboxTab(_ tab: InboxTab) -> String {
        var inner = ProtobufWriter()
        inner.varint(field: InboxField.currentTab, UInt64(tab.rawValue))
        // Sent because the capture sends it, and because the merge is per-field
        // rather than per-message: omitting it leaves whatever is stored, and
        // sending `true` records what is true here — this client has no inbox
        // tutorial, so the reader has effectively seen it.
        inner.varint(field: InboxField.viewedTutorial, 1)

        var outer = ProtobufWriter()
        outer.message(field: Field.inbox, inner.data)
        return outer.base64
    }

    private static func decodeFolder(_ source: ProtobufReader) -> GuildFolder? {
        var reader = source
        var guildIDs: [GuildID] = []
        var id: UInt64?
        var name: String?
        var color: UInt32?

        while let field = reader.next() {
            switch field.number {
            case FolderField.guildIDs:
                guildIDs = reader.packedFixed64(for: field).map { GuildID(rawValue: $0) }
            case FolderField.id:
                id = reader.wrappedValue(for: field)
            case FolderField.name:
                name = reader.wrappedString(for: field)
            case FolderField.color:
                color = reader.wrappedValue(for: field).map { UInt32(truncatingIfNeeded: $0) }
            default:
                break
            }
        }

        guard !guildIDs.isEmpty else { return nil }
        return GuildFolder(id: id, name: name, colorValue: color, guildIDs: guildIDs)
    }
}
