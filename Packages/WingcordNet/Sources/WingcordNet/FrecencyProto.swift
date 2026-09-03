import Foundation
import WingcordCore

/// `FrecencyUserSettings`, as far as the Recents row needs it.
///
/// A **second** settings protobuf, separate from the `PreloadedUserSettings`
/// that arrives on READY. It is not on READY at all and it is not in
/// `user_settings_proto`: the reference client fetches it from
/// `GET /users/@me/settings-proto/2` on demand, which is what
/// `DiscordREST.applicationFrecency()` does.
///
/// **Walked off a live capture, exactly like `UserSettingsProto`.** The blob in
/// `activities123.har` is 27,536 bytes over eight top-level fields; field 9 is
/// the one whose map keys are all snowflakes that resolve to applications the
/// account has actually launched — Watch Together, Wordle, esmBot, Poxel.io.
/// Twenty-nine entries, and the account's own Recents row is drawn from them.
///
/// ```
/// FrecencyUserSettings {
///   map<string, FrecencyItem> application_frecency = 9 {
///     string key = 1                     // the application id
///     FrecencyItem value = 2 {
///       uint32 total_uses          = 1
///       repeated uint64 recent_uses = 2  // packed, milliseconds
///       int32 frecency             = 3   // -1 on every captured entry
///       int32 score                = 4
///     }
///   }
/// }
/// ```
///
/// A malformed blob yields no entries rather than throwing, for the reason
/// `ProtobufReader` gives: an unrecognised byte must cost a row, never a
/// session.
enum FrecencyProto {

    private enum Field {
        static let applicationFrecency = 9
    }

    private enum MapEntryField {
        static let key = 1
        static let value = 2
    }

    private enum ItemField {
        static let totalUses = 1
        static let recentUses = 2
        static let score = 4
    }

    /// How often an application has been launched, and how recently.
    struct Entry: Hashable, Sendable {
        var applicationID: ApplicationID
        var totalUses: Int
        /// Discord's own score. Capped at 1000 on the captured account's two
        /// most-used apps, and **not** a function of `totalUses` alone — three
        /// launches scored 300 for one app and 70 for another, so it carries
        /// time decay the client does not have to reproduce.
        var score: Int
        /// The most recent launch. Milliseconds on the wire.
        var lastUsedAt: Date?
    }

    static func decode(base64: String) -> [Entry] {
        guard let data = Data(base64Encoded: base64) else { return [] }
        var reader = ProtobufReader(data)
        var entries: [Entry] = []
        while let field = reader.next() {
            guard field.number == Field.applicationFrecency, field.wireType == 2 else { continue }
            if let entry = self.entry(reader.reader(for: field)) { entries.append(entry) }
        }
        return entries
    }

    private static func entry(_ map: ProtobufReader) -> Entry? {
        var map = map
        var applicationID: ApplicationID?
        var item: (uses: Int, score: Int, last: Date?)?
        while let field = map.next() {
            switch field.number {
            case MapEntryField.key:
                // The key is the id as a decimal string. Anything else is a
                // different map at the same number in a future revision, and
                // dropping it is how a wrong guess stays harmless.
                applicationID = map.string(for: field).flatMap(ApplicationID.init)
            case MapEntryField.value where field.wireType == 2:
                item = self.item(map.reader(for: field))
            default:
                continue
            }
        }
        guard let applicationID, let item else { return nil }
        return Entry(
            applicationID: applicationID,
            totalUses: item.uses,
            score: item.score,
            lastUsedAt: item.last
        )
    }

    private static func item(_ reader: ProtobufReader) -> (uses: Int, score: Int, last: Date?) {
        var reader = reader
        var uses = 0
        var score = 0
        var last: UInt64 = 0
        while let field = reader.next() {
            switch field.number {
            case ItemField.totalUses where field.wireType == 0:
                uses = Int(field.value)
            case ItemField.score where field.wireType == 0:
                score = Int(field.value)
            case ItemField.recentUses where field.wireType == 2:
                // Packed varints, *not* the packed fixed64 every id list in the
                // other blob uses — these are timestamps, and they are written
                // as varints. `packedFixed64` would read them as garbage on a
                // length that happened to divide by eight.
                last = max(last, reader.packedVarints(for: field).max() ?? 0)
            default:
                continue
            }
        }
        return (uses, score, last == 0 ? nil : Date(timeIntervalSince1970: Double(last) / 1000))
    }
}

extension ProtobufReader {
    /// A packed `repeated` varint field.
    ///
    /// Stops at the first malformed byte and keeps what it already read, which
    /// for a "when was this last used" list means a slightly short answer
    /// rather than none.
    func packedVarints(for field: Field) -> [UInt64] {
        guard field.wireType == 2 else { return [] }
        var inner = reader(for: field)
        var result: [UInt64] = []
        while let value = inner.nextVarint() { result.append(value) }
        return result
    }
}
