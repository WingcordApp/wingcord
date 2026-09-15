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
//      29  default_guilds_activity_restricted_v2       varint enum
//
// **The published docs are wrong about these.** `docs.discord.food` lists the
// same fields in the same order numbered −5 at the top level and −2 inside
// `PrivacySettings`. This client's own `UserSettingsProto` — walked off a live
// READY in August — agrees with the capture. Use that page for names only.

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
    public var restrictedGuildIDs: Set<GuildID>
    public var allowsFriendsToJoin: Bool
    public var allowsVoiceParticipantsToJoin: Bool

    public init(
        sharesCurrentGame: Bool = true,
        sharingScope: ActivitySharingScope = .unset,
        restrictedGuildIDs: Set<GuildID> = [],
        allowsFriendsToJoin: Bool = true,
        allowsVoiceParticipantsToJoin: Bool = true
    ) {
        self.sharesCurrentGame = sharesCurrentGame
        self.sharingScope = sharingScope
        self.restrictedGuildIDs = restrictedGuildIDs
        self.allowsFriendsToJoin = allowsFriendsToJoin
        self.allowsVoiceParticipantsToJoin = allowsVoiceParticipantsToJoin
    }

    /// Whether activity is shared into `guildID`, given its size.
    ///
    /// The whole decision, in one place, so the pane and anything that acts on
    /// it cannot disagree.
    public func shares(in guildID: GuildID, memberCount: Int?) -> Bool {
        guard sharesCurrentGame else { return false }
        if restrictedGuildIDs.contains(guildID) { return false }
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
        static let activityRestrictedGuildIDs = 13
        static let sharingScope = 29
    }

    enum Status {
        static let showCurrentGame = 3
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
                privacy.restrictedGuildIDs = Set(
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
        case .restrictedGuildIDs(let ids):
            // Packed fixed64, in a stable order. The order carries no meaning
            // on the wire, and sorting is what makes two writes of the same set
            // produce the same bytes.
            var packed = Data()
            for id in ids.map(\.rawValue).sorted() {
                withUnsafeBytes(of: id.littleEndian) { packed.append(contentsOf: $0) }
            }
            inner.message(field: Privacy.activityRestrictedGuildIDs, packed)
        }
        let field = number(of: change)
        let merged = replacing(field: field, with: inner.data, in: raw)
        var outer = ProtobufWriter()
        outer.message(field: Top.privacy, merged)
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

    public enum Change: Hashable, Sendable {
        case friendsJoin(Bool)
        case voiceJoin(Bool)
        case sharingScope(ActivitySharingScope)
        case restrictedGuildIDs(Set<GuildID>)
    }

    private static func number(of change: Change) -> Int {
        switch change {
        case .friendsJoin: Privacy.friendsJoin
        case .voiceJoin: Privacy.voiceJoin
        case .sharingScope: Privacy.sharingScope
        case .restrictedGuildIDs: Privacy.activityRestrictedGuildIDs
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
