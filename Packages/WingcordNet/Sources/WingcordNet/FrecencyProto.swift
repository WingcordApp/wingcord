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
        static let favoriteSoundboardSounds = 8
        static let applicationFrecency = 9
        static let playedSoundFrecency = 11
        static let guildAndChannelFrecency = 12
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
        static let frecency = 3
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
        var format: UInt64?
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
                    case GIFField.format where inner.wireType == 0: format = inner.value
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
                height: height,
                isVideo: format == GIFField.video
            ),
            order
        )
    }

    private enum GIFField {
        /// 1 for a picture — a GIF, or an animated WebP — and 2 for a video
        /// rendition. Captured in `gif favorite unfavorite.har`: a Tenor entry
        /// carries `format = 2` and an MP4 in `src`.
        static let format = 1
        static let video: UInt64 = 2
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
        // Getting the kind wrong shows the entry as a broken still in every
        // other client, so it is written from the same fact it is read into.
        value.varint(field: GIFField.format, gif.isVideo ? GIFField.video : 1)
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

    // MARK: The soundboard

    private enum FavoriteSoundsField {
        static let soundIDs = 1
        static let orderedSoundIDs = 2
    }

    /// The account's starred sounds, read from Discord's own descriptor:
    ///
    /// ```
    /// FavoriteSoundboardSounds favorite_soundboard_sounds = 8 {
    ///   repeated fixed64 sound_ids         = 1
    ///   repeated fixed64 ordered_sound_ids = 2
    /// }
    /// ```
    ///
    /// Packed, as proto3 writes a repeated scalar — and an unpacked element is
    /// read as well, as every protobuf reader must.
    static func favoriteSounds(in data: Data) -> SoundboardFavorites {
        var favorites = SoundboardFavorites()
        var reader = ProtobufReader(data)
        while let field = reader.next() {
            guard field.number == Field.favoriteSoundboardSounds, field.wireType == 2 else { continue }
            var message = reader.reader(for: field)
            while let list = message.next() {
                let values: [UInt64] = switch list.wireType {
                case 2: message.packedFixed64(for: list)
                case 1: [list.value]
                default: []
                }
                switch list.number {
                case FavoriteSoundsField.soundIDs: favorites.soundIDs += values
                case FavoriteSoundsField.orderedSoundIDs: favorites.orderedSoundIDs += values
                default: continue
                }
            }
        }
        return favorites
    }

    /// The body of `PATCH /users/@me/settings-proto/2` for the favourites.
    ///
    /// Field 8 whole, because the updater replaces a top-level field — with the
    /// two lists rewritten and anything else in the message carried across as
    /// the bytes it came as.
    ///
    /// - Parameter blob: the whole frecency blob, fetched just before.
    static func favoriteSoundsPatch(_ favorites: SoundboardFavorites, in blob: Data) -> String {
        var message = Data()
        var reader = ProtobufReader(blob)
        while let field = reader.next() {
            if field.number == Field.favoriteSoundboardSounds, let data = reader.data(for: field) { message = data }
        }
        message = ActivityPrivacyProto.replacing(
            field: FavoriteSoundsField.soundIDs,
            with: packed(FavoriteSoundsField.soundIDs, favorites.soundIDs),
            in: message
        )
        message = ActivityPrivacyProto.replacing(
            field: FavoriteSoundsField.orderedSoundIDs,
            with: packed(FavoriteSoundsField.orderedSoundIDs, favorites.orderedSoundIDs),
            in: message
        )
        var top = ProtobufWriter()
        top.message(field: Field.favoriteSoundboardSounds, message)
        return top.base64
    }

    /// One packed list, or nothing for an empty one — proto3 writes no field
    /// for an empty repeated scalar.
    private static func packed(_ number: Int, _ values: [UInt64]) -> Data? {
        guard !values.isEmpty else { return nil }
        var writer = ProtobufWriter()
        writer.packedFixed64(field: number, values)
        return writer.data
    }

    /// The played-sound table whole — every entry's kept uses as well as its
    /// counts, which `SoundFrecency` scores again and writes back. Field 11,
    /// keyed by the sound's id as a string:
    ///
    /// ```
    /// PlayedSoundFrecency played_sound_frecency = 11 {
    ///   map<string, FrecencyItem> played_sounds = 1
    /// }
    /// FrecencyItem {
    ///   uint32 total_uses  = 1
    ///   repeated uint64 recent_uses = 2   // milliseconds, packed varints
    ///   int32  frecency    = 3
    ///   int32  score       = 4
    /// }
    /// ```
    static func playedSoundHistory(base64: String) -> [String: SoundFrecency.Use] {
        guard let data = Data(base64Encoded: base64) else { return [:] }
        var reader = ProtobufReader(data)
        var history: [String: SoundFrecency.Use] = [:]
        while let field = reader.next() {
            guard field.number == Field.playedSoundFrecency, field.wireType == 2 else { continue }
            var map = reader.reader(for: field)
            while let element = map.next() {
                guard element.number == mapField, element.wireType == 2 else { continue }
                var entry = map.reader(for: element)
                var key: String?
                var use: SoundFrecency.Use?
                while let part = entry.next() {
                    switch part.number {
                    case MapEntryField.key where part.wireType == 2: key = entry.string(for: part)
                    case MapEntryField.value where part.wireType == 2: use = playedSound(entry.reader(for: part))
                    default: continue
                    }
                }
                if let key, let use { history[key] = use }
            }
        }
        return history
    }

    private static func playedSound(_ reader: ProtobufReader) -> SoundFrecency.Use {
        var reader = reader
        var use = SoundFrecency.Use(totalUses: 0, recentUses: [])
        while let field = reader.next() {
            switch field.number {
            case ItemField.totalUses where field.wireType == 0: use.totalUses = Int(field.value)
            case ItemField.recentUses where field.wireType == 2: use.recentUses = reader.packedVarints(for: field)
            case ItemField.frecency where field.wireType == 0: use.frecency = Int(Int32(truncatingIfNeeded: field.value))
            case ItemField.score where field.wireType == 0: use.score = Int(Int32(truncatingIfNeeded: field.value))
            default: continue
            }
        }
        return use
    }

    /// Field 11 whole, from `SoundFrecency.written` — Discord's own write
    /// (`playedSoundFrecency.playedSounds`, the hundred most recently played).
    ///
    /// **Safe to build rather than re-frame**, the rule `ProtobufWriter` holds
    /// to: Discord's descriptor gives the wrapper one field, the map, and the
    /// item four, and all four are written here. Proto3 leaves out a zero.
    static func playedSoundsPatch(_ history: [String: SoundFrecency.Use]) -> String {
        var map = ProtobufWriter()
        for (key, use) in history.sorted(by: { $0.key < $1.key }) {
            var item = ProtobufWriter()
            if use.totalUses > 0 { item.varint(field: ItemField.totalUses, UInt64(use.totalUses)) }
            if !use.recentUses.isEmpty { item.packedVarints(field: ItemField.recentUses, use.recentUses) }
            if use.frecency > 0 { item.varint(field: ItemField.frecency, UInt64(use.frecency)) }
            if use.score > 0 { item.varint(field: ItemField.score, UInt64(use.score)) }
            var entry = ProtobufWriter()
            entry.string(field: MapEntryField.key, key)
            entry.message(field: MapEntryField.value, item.data)
            map.message(field: mapField, entry.data)
        }
        var top = ProtobufWriter()
        top.message(field: Field.playedSoundFrecency, map.data)
        return top.base64
    }

    /// Applications, by how much the account uses them.
    static func applications(base64: String) -> [Entry<ApplicationID>] {
        decode(base64: base64, field: Field.applicationFrecency) {
            $0.string(for: $1).flatMap(ApplicationID.init)
        }
    }

    /// Every server and channel the account goes to, with Discord's own score.
    ///
    /// **Field 12, and its map key is a `fixed64` where both tables above use a
    /// string.** That is the only structural difference between them and it is
    /// not guessable: read with a string key this map decodes to a hundred
    /// entries of mojibake, silently, on a blob that is perfectly well formed.
    /// Walked off `quick switcher.har` — a hundred keys, ten of which are guild
    /// ids the same capture's `quests/decision` call lists as visible, the rest
    /// channels, with scores to 1000 and last-use timestamps from the minutes
    /// the capture was taken.
    ///
    /// ```
    /// GuildAndChannelFrecency guild_and_channel_frecency = 12 {
    ///   map<fixed64, FrecencyItem> = 1     // key = a guild OR a channel id
    /// }
    /// ```
    ///
    /// **One table for both, and nothing here separates them.** A guild id and a
    /// channel id are snowflakes from one sequence and cannot collide, so the
    /// caller resolves each key against its own tables and a key that answers to
    /// neither is a place the account has left. Read, never written — the same
    /// rule the command table is held to, and for the same reason: this client
    /// understands eight fields of a twenty-eight-kilobyte message.
    static func guildsAndChannels(base64: String) -> [Entry<UInt64>] {
        decode(base64: base64, field: Field.guildAndChannelFrecency) { _, field in
            field.wireType == 1 ? field.value : nil
        }
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
        decode(base64: base64, field: Field.applicationCommandFrecency) { $0.string(for: $1) }
    }

    /// The three tables are byte-identical below the field number, and the only
    /// thing that differs is how the map's key is written — so the key is the
    /// one thing a caller supplies. It takes the reader *and* the field rather
    /// than a decoded string, because a `fixed64` key never becomes one.
    private static func decode<Key>(
        base64: String,
        field number: Int,
        key parse: (ProtobufReader, ProtobufReader.Field) -> Key?
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
        _ parse: (ProtobufReader, ProtobufReader.Field) -> Key?
    ) -> Entry<Key>? {
        var reader = reader
        var key: Key?
        var item: (uses: Int, score: Int, last: Date?)?
        while let field = reader.next() {
            switch field.number {
            case MapEntryField.key:
                // **The caller owns the wire type as well as the parse.**
                // Anything it cannot read is a different map at the same number
                // in a future revision, and dropping it is how a wrong guess
                // stays harmless.
                key = parse(reader, field)
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
