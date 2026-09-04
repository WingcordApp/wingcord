import Foundation
import WingcordCore

/// `FrecencyUserSettings` — how often the account has launched each app, and
/// how often it has run each command.
///
/// A **second** settings protobuf, separate from the `PreloadedUserSettings`
/// that arrives on READY. It is not on READY at all and it is not in
/// `user_settings_proto`: the reference client fetches it from
/// `GET /users/@me/settings-proto/2` on demand.
///
/// **Walked off a live capture, exactly like `UserSettingsProto`.** The blob in
/// `activities123.har` is 27,536 bytes over eight top-level fields. Field 9's
/// map keys are all snowflakes that resolve to applications the account has
/// launched — Watch Together, Wordle, esmBot, Poxel.io — and field 7's resolve
/// against the command index to `count`, `help`, `ping`, `wordle`, `avatar`,
/// `image`, `gif`, which are the rows Discord's own "Frequently Used" section
/// draws.
///
/// ```
/// FrecencyUserSettings {
///   ApplicationCommandFrecency application_command_frecency = 7 {
///     map<string, FrecencyItem> = 1        // key = command id
///   }
///   ApplicationFrecency application_frecency = 9 {
///     map<string, FrecencyItem> = 1        // key = application id
///   }
///   FrecencyItem {
///     uint32 total_uses           = 1
///     repeated uint64 recent_uses = 2      // packed varints, milliseconds
///     int32 frecency              = 3      // -1 on every captured entry
///     int32 score                 = 4
///   }
/// }
/// ```
///
/// **The map is one level below the field, and getting that wrong is silent.**
/// This decoder read field 9's payload *as* a map entry for one release: every
/// field it then saw was numbered `1`, so it took each map entry's raw bytes as
/// a key string, failed to parse a snowflake out of them, and answered an empty
/// array — on a blob that decodes perfectly. The Recents row went blank on every
/// live account while the unit test passed, because the test's fixture had been
/// hand-re-framed at the shallow depth the decoder expected. The fixtures below
/// are now the capture's own bytes with their wrapper intact.
///
/// A malformed blob yields no entries rather than throwing, for the reason
/// `ProtobufReader` gives: an unrecognised byte must cost a row, never a
/// session.
enum FrecencyProto {

    private enum Field {
        static let favoriteGIFs = 2
        static let applicationCommandFrecency = 7
        static let applicationFrecency = 9
    }

    /// The map inside each wrapper. `1` for both, and named once so the two
    /// call sites cannot disagree about it.
    private static let mapField = 1

    private enum MapEntryField {
        static let key = 1
        static let value = 2
    }

    private enum ItemField {
        static let totalUses = 1
        static let recentUses = 2
        static let score = 4
    }

    /// How often something has been used, and how recently.
    ///
    /// Generic over its key, because the two tables are byte-identical below
    /// the field number and an application id and a command id are different
    /// types in this codebase. A command's key is a `String`: Discord's own
    /// built-in commands are keyed negative — the capture has an entry for
    /// `-6` — so a reader that insists on `UInt64` cannot read the table back.
    struct Entry<Key: Hashable & Sendable>: Hashable, Sendable {
        var key: Key
        var totalUses: Int
        /// Discord's own score. Capped at 1000 on the captured account's two
        /// most-used apps, and **not** a function of `totalUses` alone — three
        /// launches scored 300 for one app and 70 for another, so it carries
        /// time decay the client does not have to reproduce.
        var score: Int
        /// The most recent use. Milliseconds on the wire.
        var lastUsedAt: Date?
    }

    /// **The ordering is the one thing here that is not confirmed.** Sorted by
    /// Discord's stored `score`, then by most recent use. Neither field on its
    /// own reproduces the order the reference client drew in the capture's own
    /// screenshot, which suggests it recomputes a decayed score at read time
    /// rather than trusting the stored one. The rows are right; the order
    /// within them may not be.
    static func mostUsedFirst<Key>(_ lhs: Entry<Key>, _ rhs: Entry<Key>) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        return (lhs.lastUsedAt ?? .distantPast) > (rhs.lastUsedAt ?? .distantPast)
    }

    /// The account's starred GIFs, in the order it arranged them.
    ///
    /// **Field 2 of the FRECENCY blob, not field 15 of the preloaded one.**
    /// `PreloadedUserSettings` does declare a `favorites`, and this client read
    /// it there for a release — but the captured type-1 blob has no field 15 at
    /// all, so the Favourites tile was drawn from an array that was always
    /// empty. The GIFs are here, beside the frecency tables, in the same
    /// wrapper-then-map shape everything else in this message uses.
    ///
    /// ```
    /// FavoriteGIFs favorite_gifs = 2 {
    ///   map<string, FavoriteGIF> = 1     // key = the GIF's own URL
    /// }
    /// FavoriteGIF {
    ///   int32  format = 1                // 1 image, 2 video
    ///   string src    = 2                // the proxied rendition
    ///   uint32 width  = 3
    ///   uint32 height = 4
    ///   uint32 order  = 5
    /// }
    /// ```
    ///
    /// **Sorted by `order`, descending.** It is an insertion counter — the
    /// captured account's eighteen favourites run 1 through 18 with no gaps —
    /// so the highest is the one most recently starred, and that is the one
    /// Discord puts first. Ascending order draws the reader's oldest favourite
    /// at the top of the grid, which is the wrong end of a list nobody scrolls.
    /// A map carries no order at all, so without this the tile opens onto
    /// whatever sequence the protobuf happened to serialise.
    static func favoriteGIFs(base64: String) -> [GIF] {
        guard let data = Data(base64Encoded: base64) else { return [] }
        var reader = ProtobufReader(data)
        var found: [(gif: GIF, order: Int)] = []
        while let field = reader.next() {
            guard field.number == Field.favoriteGIFs, field.wireType == 2 else { continue }
            var map = reader.reader(for: field)
            while let element = map.next() {
                guard element.number == mapField, element.wireType == 2 else { continue }
                if let entry = favoriteGIF(map.reader(for: element)) { found.append(entry) }
            }
        }
        return found.sorted { $0.order > $1.order }.map(\.gif)
    }

    private static func favoriteGIF(_ source: ProtobufReader) -> (gif: GIF, order: Int)? {
        var reader = source
        var key: String?
        var src: String?
        var width: Int?
        var height: Int?
        var order = Int.max

        while let field = reader.next() {
            switch field.number {
            case MapEntryField.key where field.wireType == 2:
                key = reader.string(for: field)
            case MapEntryField.value where field.wireType == 2:
                var value = reader.reader(for: field)
                while let inner = value.next() {
                    switch inner.number {
                    case GIFField.src where inner.wireType == 2: src = value.string(for: inner)
                    case GIFField.width where inner.wireType == 0: width = Int(inner.value)
                    case GIFField.height where inner.wireType == 0: height = Int(inner.value)
                    case GIFField.order where inner.wireType == 0: order = Int(inner.value)
                    default: continue
                    }
                }
            default:
                continue
            }
        }
        // **The key must really be an `https` URL.** It is the whole safety net
        // against a field number that has moved: a wrong one yields nothing here
        // rather than the plausible nonsense a protobuf otherwise answers with.
        guard let key, let url = URL(string: key), url.scheme == "https" else { return nil }
        return (
            GIF(
                url: url,
                previewURL: src.flatMap(URL.init(string:)),
                width: width,
                height: height
            ),
            order
        )
    }

    private enum GIFField {
        /// 1 for a still, 2 for a video rendition. Captured in
        /// `gif favorite unfavorite.har`: a Tenor entry carries `format = 2`.
        static let format = 1
        static let src = 2
        static let width = 3
        static let height = 4
        static let order = 5
    }

    // MARK: Writing a favourite back

    /// One favourite, as it sits on the wire.
    ///
    /// **The entry's own bytes are kept.** Rewriting the map means re-emitting
    /// every entry, and an entry rebuilt from the five fields above loses
    /// anything Discord adds to it later — for every favourite the account has,
    /// silently, the first time somebody stars a new one. Re-framing the bytes
    /// that arrived cannot lose what it never parsed.
    public struct FavoriteEntry: Sendable {
        /// The GIF's own URL, which is the map key.
        public var key: String
        /// The insertion counter. The highest is the most recent.
        public var order: Int
        /// The map entry's payload, framing excluded.
        public var raw: Data
    }

    /// The account's favourites, each with the bytes it arrived as.
    public static func favoriteGIFEntries(base64: String) -> [FavoriteEntry] {
        guard let data = Data(base64Encoded: base64) else { return [] }
        var reader = ProtobufReader(data)
        var found: [FavoriteEntry] = []
        while let field = reader.next() {
            guard field.number == Field.favoriteGIFs, field.wireType == 2 else { continue }
            var map = reader.reader(for: field)
            while let element = map.next() {
                guard element.number == mapField, element.wireType == 2,
                      let raw = map.data(for: element)
                else { continue }
                var entry = map.reader(for: element)
                var key: String?
                var order = 0
                while let inner = entry.next() {
                    switch inner.number {
                    case MapEntryField.key where inner.wireType == 2:
                        key = entry.string(for: inner)
                    case MapEntryField.value where inner.wireType == 2:
                        var value = entry.reader(for: inner)
                        while let leaf = value.next() {
                            guard leaf.number == GIFField.order, leaf.wireType == 0 else {
                                continue
                            }
                            order = Int(leaf.value)
                        }
                    default:
                        continue
                    }
                }
                guard let key else { continue }
                found.append(FavoriteEntry(key: key, order: order, raw: raw))
            }
        }
        return found
    }

    /// The whole `favorite_gifs` field, ready to PATCH.
    ///
    /// **The field is replaced, not merged, and the capture is what says so.**
    /// Unfavouriting sent a *smaller* map — 5,101 bytes where the favourite that followed
    /// sent 5,424 — which a merge could not express, because a map merges by key
    /// and has no way to say "this one is gone". So the whole map goes every
    /// time, and every entry that is staying goes as the bytes it arrived as.
    public static func encodeFavoriteGIFs(_ entries: [FavoriteEntry]) -> String {
        var map = ProtobufWriter()
        for entry in entries { map.message(field: mapField, entry.raw) }
        var top = ProtobufWriter()
        top.message(field: Field.favoriteGIFs, map.data)
        return top.base64
    }

    /// Builds the map entry for a GIF the account has just starred.
    ///
    /// The shape is the capture's, field for field: a key, then a value holding
    /// the format, the proxied rendition, the pixel size and the insertion
    /// counter. `order` is the caller's — one past the highest it already has,
    /// which is what puts a new favourite at the front of the grid.
    public static func favoriteEntry(for gif: GIF, order: Int) -> FavoriteEntry {
        var value = ProtobufWriter()
        // 1 is a still and 2 is a video rendition. Discord serves Tenor results
        // as `.mp4`, so anything whose preview is one is a video — and getting
        // this wrong shows the entry as a broken still in every other client.
        let isVideo = (gif.previewURL ?? gif.url).pathExtension.lowercased() == "mp4"
        value.varint(field: GIFField.format, isVideo ? 2 : 1)
        if let src = gif.previewURL?.absoluteString ?? Optional(gif.url.absoluteString) {
            value.string(field: GIFField.src, src)
        }
        if let width = gif.width, width > 0 { value.varint(field: GIFField.width, UInt64(width)) }
        if let height = gif.height, height > 0 {
            value.varint(field: GIFField.height, UInt64(height))
        }
        value.varint(field: GIFField.order, UInt64(max(0, order)))

        var entry = ProtobufWriter()
        entry.string(field: MapEntryField.key, gif.url.absoluteString)
        entry.message(field: MapEntryField.value, value.data)
        return FavoriteEntry(key: gif.url.absoluteString, order: order, raw: entry.data)
    }

    /// Applications, by how much the account uses them.
    static func applications(base64: String) -> [Entry<ApplicationID>] {
        decode(base64: base64, field: Field.applicationFrecency, key: ApplicationID.init)
    }

    /// Commands, by how much the account uses them.
    ///
    /// The key is kept as written. It is a bare command id for almost every
    /// entry, and three of the captured thirty-seven are a **pair** joined by a
    /// colon — `1409934331119669309:1375169799209877635`. Which half is which is
    /// not derivable from the capture, so nothing here splits it: an unresolved
    /// key simply matches no command and costs that one row its place in the
    /// Frequently Used list.
    static func commands(base64: String) -> [Entry<String>] {
        decode(base64: base64, field: Field.applicationCommandFrecency, key: { String($0) })
    }

    private static func decode<Key>(
        base64: String,
        field number: Int,
        key parse: (String) -> Key?
    ) -> [Entry<Key>] {
        guard let data = Data(base64Encoded: base64) else { return [] }
        var reader = ProtobufReader(data)
        var entries: [Entry<Key>] = []
        while let field = reader.next() {
            guard field.number == number, field.wireType == 2 else { continue }
            // The wrapper message. Its own repeated field 1 is the map.
            var map = reader.reader(for: field)
            while let element = map.next() {
                guard element.number == mapField, element.wireType == 2 else { continue }
                if let entry = self.entry(map.reader(for: element), parse) {
                    entries.append(entry)
                }
            }
        }
        return entries
    }

    private static func entry<Key>(
        _ reader: ProtobufReader,
        _ parse: (String) -> Key?
    ) -> Entry<Key>? {
        var reader = reader
        var key: Key?
        var item: (uses: Int, score: Int, last: Date?)?
        while let field = reader.next() {
            switch field.number {
            case MapEntryField.key where field.wireType == 2:
                // Anything the caller cannot parse is a different map at the
                // same number in a future revision, and dropping it is how a
                // wrong guess stays harmless.
                key = reader.string(for: field).flatMap(parse)
            case MapEntryField.value where field.wireType == 2:
                item = self.item(reader.reader(for: field))
            default:
                continue
            }
        }
        guard let key, let item else { return nil }
        return Entry(key: key, totalUses: item.uses, score: item.score, lastUsedAt: item.last)
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
