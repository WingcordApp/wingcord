import Foundation
import WingcordCore

// MARK: - Activity privacy, in `PreloadedUserSettings`
//
// **Every field number here was walked out of eight captured PATCHes**, one
// control toggled at a time with the Network tab open, 2026-09-14. The method
// is the one that settled the inbox tab from six bytes, and `docs/OVERLAY.md`
// has the table and the diffs that pin each number.
//
//     PreloadedUserSettings
//       7  notifications
//       8  privacy          ← everything below
//      11  status             { 3 = show_current_game }
//
//     PrivacySettings
//       1  allow_activity_party_privacy_friends        BoolValue
//       2  allow_activity_party_privacy_voice_channel  BoolValue
//       3  restricted_guild_ids                        packed fixed64
//      13  activity_restricted_guild_ids               packed fixed64
//      15  activity_joining_restricted_guild_ids       packed fixed64
//      16  message_request_restricted_guild_ids        packed fixed64
//      29  default_guilds_activity_restricted_v2       varint enum
//
// **3, 15 and 16 are the per-server Privacy Settings sheet**, and 3 and 15 were
// pinned a second time by `serveroptions + privacy.har` (2026-09-22): the three
// switches were turned off top to bottom and back on bottom to top, and the six
// PATCHes differ in exactly those three fields and nothing else. 16 is the one
// switch that capture does NOT contain, and it is not a guess either — it is
// read out of Discord's own compiled descriptor in the app bundle, where
// `PrivacySettings` is declared field by field with its numbers.
//
// **The published docs are wrong about these.** `docs.discord.food` lists the
// same fields in the same order numbered −5 at the top level and −2 inside
// `PrivacySettings`, and the offset is not even constant — it is −2 from field 9
// to 16 and 0 again by 22. This client's own `UserSettingsProto` — walked off a
// live READY in August — agrees with the capture and with the bundle. Use that
// page for names only.

/// Where the account shares what it is playing.
///
/// **The polarity is inverted and the enum's own name lies about it.** The
/// field is `…Restricted`, so `.everywhere` — the case that means "share in
/// every server" — is the one that turns the restriction *off*. A client that
/// read `restricted = on` as "sharing on" would broadcast exactly what the
/// reader asked it to hide, which is the worst direction a privacy setting can
/// fail in. Pinned by `ActivityPrivacyTests`.
public enum ActivitySharingScope: UInt64, Hashable, Sendable, CaseIterable {
    /// The account has never answered. Treated as `.everywhere`, which is what
    /// Discord's own client falls back to.
    case unset = 0
    /// "Share in all servers."
    case everywhere = 1
    /// "Share in servers with 200 or fewer members."
    case smallServersOnly = 2
    /// "Do not share in any servers." Friends still see it.
    case friendsOnly = 3

    public var title: String {
        switch self {
        case .unset, .everywhere: "Share in all servers"
        case .smallServersOnly: "Share in servers with 200 or fewer members"
        case .friendsOnly: "Do not share in any servers"
        }
    }

    /// The membership count that divides "small" from "large".
    ///
    /// **Two hundred, hard-coded**, and read out of the client rather than
    /// guessed: the comparison in the bundle is literally `n > 200` / `n <= 200`
    /// against the guild's member count.
    public static let smallServerCeiling = 200
}

/// The account's activity-privacy settings, as far as this client reads them.
public struct ActivityPrivacy: Hashable, Sendable {
    public var sharesCurrentGame: Bool
    public var sharingScope: ActivitySharingScope
    /// Servers the reader has switched off by hand.
    public var activityRestrictedGuildIDs: Set<GuildID>
    public var allowsFriendsToJoin: Bool
    public var allowsVoiceParticipantsToJoin: Bool
    /// Servers the reader has switched direct messages off in — field 3, which
    /// is a **different list** from the one above however similar the wire's
    /// two names look.
    public var dmRestrictedGuildIDs: Set<GuildID>
    /// Servers nobody may join the reader's game from — field 15.
    public var activityJoiningRestrictedGuildIDs: Set<GuildID>
    /// Servers whose DMs bypass the message-request filter — field 16.
    public var messageRequestRestrictedGuildIDs: Set<GuildID>

    public init(
        sharesCurrentGame: Bool = true,
        sharingScope: ActivitySharingScope = .unset,
        activityRestrictedGuildIDs: Set<GuildID> = [],
        allowsFriendsToJoin: Bool = true,
        allowsVoiceParticipantsToJoin: Bool = true,
        dmRestrictedGuildIDs: Set<GuildID> = [],
        activityJoiningRestrictedGuildIDs: Set<GuildID> = [],
        messageRequestRestrictedGuildIDs: Set<GuildID> = []
    ) {
        self.sharesCurrentGame = sharesCurrentGame
        self.sharingScope = sharingScope
        self.activityRestrictedGuildIDs = activityRestrictedGuildIDs
        self.allowsFriendsToJoin = allowsFriendsToJoin
        self.allowsVoiceParticipantsToJoin = allowsVoiceParticipantsToJoin
        self.dmRestrictedGuildIDs = dmRestrictedGuildIDs
        self.activityJoiningRestrictedGuildIDs = activityJoiningRestrictedGuildIDs
        self.messageRequestRestrictedGuildIDs = messageRequestRestrictedGuildIDs
    }

    /// The per-server Privacy sheet, for one server.
    ///
    /// **Every switch is the ABSENCE of the id.** Each of these is a restriction
    /// list, so a server nobody has touched is in none of them and every switch
    /// reads on — which is what the sheet shows for a fresh account.
    public func privacy(in guildID: GuildID) -> GuildPrivacy {
        GuildPrivacy(
            allowsDirectMessages: !dmRestrictedGuildIDs.contains(guildID),
            filtersMessageRequests: !messageRequestRestrictedGuildIDs.contains(guildID),
            sharesActivity: !activityRestrictedGuildIDs.contains(guildID),
            allowsActivityJoining: !activityJoiningRestrictedGuildIDs.contains(guildID)
        )
    }

    /// The list behind one switch, and the change that flips it.
    public func guildIDs(for toggle: GuildPrivacyToggle) -> Set<GuildID> {
        switch toggle {
        case .directMessages: dmRestrictedGuildIDs
        case .messageRequests: messageRequestRestrictedGuildIDs
        case .activitySharing: activityRestrictedGuildIDs
        case .activityJoining: activityJoiningRestrictedGuildIDs
        }
    }

    public mutating func setGuildIDs(_ ids: Set<GuildID>, for toggle: GuildPrivacyToggle) {
        switch toggle {
        case .directMessages: dmRestrictedGuildIDs = ids
        case .messageRequests: messageRequestRestrictedGuildIDs = ids
        case .activitySharing: activityRestrictedGuildIDs = ids
        case .activityJoining: activityJoiningRestrictedGuildIDs = ids
        }
    }

    /// Whether activity is shared into `guildID`, given its size.
    ///
    /// The whole decision, in one place, so the pane and anything that acts on
    /// it cannot disagree.
    public func shares(in guildID: GuildID, memberCount: Int?) -> Bool {
        guard sharesCurrentGame else { return false }
        if activityRestrictedGuildIDs.contains(guildID) { return false }
        switch sharingScope {
        case .unset, .everywhere: return true
        case .friendsOnly: return false
        case .smallServersOnly:
            // An unknown size is treated as large. The conservative direction:
            // a client that guessed "small" would share into a server it could
            // not measure.
            guard let memberCount else { return false }
            return memberCount <= ActivitySharingScope.smallServerCeiling
        }
    }
}

// MARK: - Reading and writing it

public enum ActivityPrivacyProto {

    enum Top {
        static let privacy = 8
        static let status = 11
    }

    enum Privacy {
        static let friendsJoin = 1
        static let voiceJoin = 2
        /// Servers the reader will not accept direct messages from.
        static let dmRestrictedGuildIDs = 3
        static let activityRestrictedGuildIDs = 13
        static let activityJoiningRestrictedGuildIDs = 15
        /// Servers whose DMs skip the message-request filter.
        static let messageRequestRestrictedGuildIDs = 16
        static let sharingScope = 29
    }

    /// The three lists the per-server Privacy sheet edits, by their field number.
    ///
    /// One table rather than a `switch` in four places: a decode, a write, a
    /// membership test and an optimistic update all ask the same question, and
    /// three of them getting it right is a privacy setting that silently
    /// disagrees with itself.
    static func field(for toggle: GuildPrivacyToggle) -> Int {
        switch toggle {
        case .directMessages: Privacy.dmRestrictedGuildIDs
        case .messageRequests: Privacy.messageRequestRestrictedGuildIDs
        case .activitySharing: Privacy.activityRestrictedGuildIDs
        case .activityJoining: Privacy.activityJoiningRestrictedGuildIDs
        }
    }

    enum Status {
        static let status = 1
        static let customStatus = 2
        static let showCurrentGame = 3
    }

    /// `discord_protos.discord_users.v1.CustomStatus`, field for field.
    ///
    /// **Lifted from Discord's own compiled descriptor**, where the message is
    /// declared beside `StatusSettings`: text, the emoji as an id *and* a name,
    /// and two millisecond clocks. `emoji_id` and `expires_at_ms` are
    /// **fixed64**, not varints — a writer that sent them as varints would be
    /// writing a well-formed message Discord reads as something else.
    enum CustomStatusField {
        static let text = 1
        static let emojiID = 2
        static let emojiName = 3
        static let expiresAtMS = 4
        static let createdAtMS = 5
    }

    /// Everything this client understands, out of a whole settings blob.
    ///
    /// The **raw** `privacy` message comes back beside the values, because
    /// writing one field back safely means keeping every other byte — see
    /// `replacing(field:with:in:)`.
    public static func decode(
        _ blob: Data
    ) -> (privacy: ActivityPrivacy, raw: Data?, statusRaw: Data?) {
        var privacy = ActivityPrivacy()
        var raw: Data?
        var statusRaw: Data?
        var reader = ProtobufReader(blob)
        while let field = reader.next() {
            switch field.number {
            case Top.privacy:
                guard let data = reader.data(for: field) else { break }
                raw = data
                decodePrivacy(data, into: &privacy)
            case Top.status:
                statusRaw = reader.data(for: field)
                var inner = reader.reader(for: field)
                while let entry = inner.next() {
                    guard entry.number == Status.showCurrentGame else { continue }
                    // A `BoolValue`: an empty message is `false`, and a message
                    // carrying field 1 = 1 is `true`. Both are wire type 2, so
                    // **the emptiness IS the value** and there is nothing to
                    // read. A decoder that required a payload here would report
                    // `true` for an account that had switched sharing off.
                    privacy.sharesCurrentGame = (inner.wrappedValue(for: entry) ?? 0) != 0
                }
            default:
                break
            }
        }
        return (privacy, raw, statusRaw)
    }

    private static func decodePrivacy(_ data: Data, into privacy: inout ActivityPrivacy) {
        var reader = ProtobufReader(data)
        while let field = reader.next() {
            switch field.number {
            case Privacy.friendsJoin:
                privacy.allowsFriendsToJoin = (reader.wrappedValue(for: field) ?? 0) != 0
            case Privacy.voiceJoin:
                privacy.allowsVoiceParticipantsToJoin = (reader.wrappedValue(for: field) ?? 0) != 0
            case Privacy.activityRestrictedGuildIDs:
                privacy.activityRestrictedGuildIDs = Set(
                    reader.packedFixed64(for: field).map { GuildID(rawValue: $0) }
                )
            case Privacy.dmRestrictedGuildIDs:
                privacy.dmRestrictedGuildIDs = Set(
                    reader.packedFixed64(for: field).map { GuildID(rawValue: $0) }
                )
            case Privacy.activityJoiningRestrictedGuildIDs:
                privacy.activityJoiningRestrictedGuildIDs = Set(
                    reader.packedFixed64(for: field).map { GuildID(rawValue: $0) }
                )
            case Privacy.messageRequestRestrictedGuildIDs:
                privacy.messageRequestRestrictedGuildIDs = Set(
                    reader.packedFixed64(for: field).map { GuildID(rawValue: $0) }
                )
            case Privacy.sharingScope:
                privacy.sharingScope = ActivitySharingScope(rawValue: field.value) ?? .unset
            default:
                break
            }
        }
    }

    // MARK: Writing

    /// Replaces one field inside a message, keeping every other byte verbatim.
    ///
    /// **This is the whole safety argument, and it is the same one
    /// `ProtobufWriter` makes at the top of its own file.** A writer that
    /// re-serialises a message it only partly understands does not fail loudly;
    /// it silently deletes the fields it could not name — here that would be
    /// somebody's `restricted_guild_ids`, their friend-source flags and their
    /// message-request settings. So every field that is not the one being
    /// changed is copied across as the bytes it arrived as, unread.
    ///
    /// A field that was not present is appended. A `nil` replacement removes it.
    static func replacing(field number: Int, with encoded: Data?, in message: Data) -> Data {
        var out = Data()
        var replaced = false
        var reader = ProtobufReader(message)
        while let field = reader.next() {
            guard let bytes = reader.rawField(field) else { continue }
            if field.number == number {
                if !replaced, let encoded { out.append(encoded) }
                replaced = true
                continue
            }
            out.append(bytes)
        }
        if !replaced, let encoded { out.append(encoded) }
        return out
    }

    /// The body of `PATCH /users/@me/settings-proto/1` for one privacy change.
    ///
    /// - Parameter raw: the `privacy` message exactly as it arrived. **Required**:
    ///   without it there is nothing to preserve, and the caller must fetch the
    ///   blob before it can write one.
    public static func privacyPatch(
        applying change: Change,
        to raw: Data
    ) -> String {
        var inner = ProtobufWriter()
        switch change {
        case .friendsJoin(let allowed):
            inner.message(field: Privacy.friendsJoin, boolValue(allowed))
        case .voiceJoin(let allowed):
            inner.message(field: Privacy.voiceJoin, boolValue(allowed))
        case .sharingScope(let scope):
            inner.tag(field: Privacy.sharingScope, wireType: 0)
            inner.varint(scope.rawValue)
        case .activityRestrictedGuildIDs(let ids):
            inner.message(field: Privacy.activityRestrictedGuildIDs, Self.packed(ids))
        case .guildList(let toggle, let ids):
            inner.message(field: Self.field(for: toggle), Self.packed(ids))
        }
        let field = number(of: change)
        let merged = replacing(field: field, with: inner.data, in: raw)
        var outer = ProtobufWriter()
        outer.message(field: Top.privacy, merged)
        return outer.base64
    }

    /// Reads the custom status out of a whole settings blob.
    ///
    /// **Nothing read this before and the status was lost on every launch.**
    /// `publishPresence` broadcasts one over the socket, which is how everybody
    /// else sees it — but the value itself lives in the settings blob, and this
    /// client decoded `status.1` and stopped. So a status survived until the app
    /// was quit and then silently was not there.
    public static func decodeCustomStatus(_ blob: Data) -> CustomStatus? {
        var reader = ProtobufReader(blob)
        while let field = reader.next() {
            guard field.number == Top.status else { continue }
            var inner = reader.reader(for: field)
            while let entry = inner.next() {
                guard entry.number == Status.customStatus else { continue }
                return decodeCustomStatusMessage(inner.reader(for: entry))
            }
        }
        return nil
    }

    private static func decodeCustomStatusMessage(_ reader: ProtobufReader) -> CustomStatus? {
        var reader = reader
        var text: String?
        var emojiID: EmojiID?
        var emojiName: String?
        var expiry: Date?
        while let field = reader.next() {
            switch field.number {
            case CustomStatusField.text:
                text = reader.string(for: field)
            case CustomStatusField.emojiID:
                // Zero is the absence, not an id — §5.8, "a zero snowflake is
                // not an id, and it is the most dangerous value there is".
                if field.value != 0 { emojiID = EmojiID(rawValue: field.value) }
            case CustomStatusField.emojiName:
                emojiName = reader.string(for: field)
            case CustomStatusField.expiresAtMS:
                if field.value != 0 {
                    expiry = Date(timeIntervalSince1970: Double(field.value) / 1000)
                }
            default:
                break
            }
        }
        let emoji = emojiName.flatMap { name -> EmojiRef? in
            name.isEmpty ? nil : EmojiRef(id: emojiID, name: name)
        }
        let status = CustomStatus(text: text, emoji: emoji, expiresAt: expiry)
        return status.isEmpty ? nil : status
    }

    /// The body of `PATCH /users/@me/settings-proto/1` for one custom status.
    ///
    /// **The whole `CustomStatus` message is rebuilt, and that is correct
    /// here** where it would not be for `privacy`: it is five fields, this
    /// client reads four of them, and the fifth — `created_at_ms` — is one
    /// Discord recomputes. The `status` message *around* it is spliced as
    /// always, so the presence and its expiry are carried across untouched.
    ///
    /// A nil status clears it: the field is removed rather than written empty,
    /// which is what Discord's own Clear does.
    public static func customStatusPatch(_ status: CustomStatus?, statusRaw: Data?) -> String {
        var encoded: Data?
        if let status, !status.isEmpty {
            var inner = ProtobufWriter()
            if let text = status.text { inner.string(field: CustomStatusField.text, text) }
            if let emoji = status.emoji {
                if let id = emoji.id {
                    inner.fixed64(field: CustomStatusField.emojiID, id.rawValue)
                }
                inner.string(field: CustomStatusField.emojiName, emoji.name)
            }
            if let expiry = status.expiresAt {
                inner.fixed64(
                    field: CustomStatusField.expiresAtMS,
                    UInt64(max(0, expiry.timeIntervalSince1970 * 1000))
                )
            }
            var wrapper = ProtobufWriter()
            wrapper.message(field: Status.customStatus, inner.data)
            encoded = wrapper.data
        }
        let merged = replacing(
            field: Status.customStatus,
            with: encoded,
            in: statusRaw ?? Data()
        )
        var outer = ProtobufWriter()
        outer.message(field: Top.status, merged)
        return outer.base64
    }

    /// The body for "Share my activity", which lives on `status`, not `privacy`.
    ///
    /// **Its whole sub-message is rebuilt rather than spliced**, and that is
    /// safe here where it would not be for `privacy`: `status` is three fields,
    /// this client reads two of them, and the third — the expiry timestamp —
    /// is carried across verbatim by the same splice. Nothing is dropped.
    public static func showCurrentGamePatch(_ shares: Bool, statusRaw: Data?) -> String {
        var inner = ProtobufWriter()
        inner.message(field: Status.showCurrentGame, boolValue(shares))
        let merged = replacing(
            field: Status.showCurrentGame,
            with: inner.data,
            in: statusRaw ?? Data()
        )
        var outer = ProtobufWriter()
        outer.message(field: Top.status, merged)
        return outer.base64
    }

    /// Packed fixed64, in a stable order.
    ///
    /// The order carries no meaning on the wire, and sorting is what makes two
    /// writes of the same set produce the same bytes — which is what lets a
    /// test assert a round trip rather than a set comparison.
    static func packed(_ ids: Set<GuildID>) -> Data {
        var packed = Data()
        for id in ids.map(\.rawValue).sorted() {
            withUnsafeBytes(of: id.littleEndian) { packed.append(contentsOf: $0) }
        }
        return packed
    }

    public enum Change: Hashable, Sendable {
        case friendsJoin(Bool)
        case voiceJoin(Bool)
        case sharingScope(ActivitySharingScope)
        case activityRestrictedGuildIDs(Set<GuildID>)
        /// One of the per-server Privacy sheet's four lists, whole.
        ///
        /// **The whole list, never a delta**, because the field is replaced
        /// rather than merged — `INVARIANTS.md` §5.6, "whether a settings field
        /// merges or is replaced is a capture, not a guess". The capture proves
        /// it here too: switching a server's DMs back on sent a list one id
        /// SHORTER, which a merge cannot express.
        case guildList(GuildPrivacyToggle, Set<GuildID>)
    }

    private static func number(of change: Change) -> Int {
        switch change {
        case .friendsJoin: Privacy.friendsJoin
        case .voiceJoin: Privacy.voiceJoin
        case .sharingScope: Privacy.sharingScope
        case .activityRestrictedGuildIDs: Privacy.activityRestrictedGuildIDs
        case .guildList(let toggle, _): field(for: toggle)
        }
    }

    /// A `google.protobuf.BoolValue`.
    ///
    /// **`false` is an EMPTY message, not field 1 = 0.** Proto3 does not write
    /// a scalar at its default, so the wrapper carrying `false` is zero bytes
    /// long — which is exactly what the capture shows for both join toggles
    /// after they were switched off.
    static func boolValue(_ value: Bool) -> Data {
        guard value else { return Data() }
        var writer = ProtobufWriter()
        writer.varint(field: 1, 1)
        return writer.data
    }
}
