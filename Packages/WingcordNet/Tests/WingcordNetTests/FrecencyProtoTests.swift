import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// `GET /users/@me/settings-proto/2` — the tables the Recents row and the
/// Frequently Used section are drawn from.
///
/// **The bytes below are the account's own, with their framing intact.** Three
/// map entries from field 9 and six from field 7, lifted verbatim out of the
/// 27,536-byte blob in `activities123.har` and re-framed *inside their
/// wrappers*, which is the part that matters here.
///
/// The previous fixture dropped that wrapper: it wrote each map entry directly
/// as field 9, one level shallower than Discord does. The decoder had the same
/// mistake, so the test passed and the live blob decoded to nothing — the
/// Recents row was blank on every real account while this suite was green. A
/// protobuf read with the wrong field numbers does not fail, it answers
/// plausible nonsense; the only defence is a fixture that is byte-identical to
/// the wire, wrapper included.
@Suite("Frecency")
struct FrecencyProtoTests {

    /// Field 9 (`application_frecency`) then field 7
    /// (`application_command_frecency`), each a real wrapper containing real map
    /// entries. Nothing here was reconstructed.
    private let blob = """
    SogCCjkKEjk0OTQ3OTMzODI3NTkxMzc5ORIjCAMSEubB3K/9M9/Lk4OBNN/Lk4OBNBj///////////8B\
    IEYKZQoTMTIxMTc4MTQ4OTkzMTQ1MjQ0NxJOCBsSPMDPoIT/M8DPoIT/M8DPoIT/M6uQoYT/M6uQoYT/\
    M6uQoYT/M6+WqoT/M6+WqoT/M6+WqoT/M8eKn6b/Mxj///////////8BIOgHCmQKEjg4MDIxODM5NDE5\
    OTIyMDMzNBJOCGoSPOW4x5eGNKq+x5eGNKq+x5eGNPWxyJeGNPWxyJeGNKG0yJeGNKG0yJeGNOzAyJeG\
    NOzAyJeGNI6RzZeGNBj///////////8BIOgHOr4CCj0KEjk5MTE5NTE3ODEwMDU5MjY3NBInCAQSGLDM\
    soSBNLDMsoSBNIiJs4SBNIiJs4SBNBj///////////8BCjoKEzEwNTYxMjQ2MDE1MjYxMjg2NzESIwgD\
    EhLnwdyv/TPfy5ODgTTfy5ODgTQY////////////ASABCjMKEjk5MTE5NTE3ODIzMDYyMDI1NBIdCAIS\
    DJSn8a79M6y51a/9Mxj///////////8BIAEKOgoTMTMzMTM1Mzc0OTI0NzIzNDEzORIjCAMSEuftgtTt\
    MvCt0r2YM42HuJ79Mxj///////////8BIAEKLQoSOTkxMTk1MTc4MDIwODk2ODQ3EhcIARIG/8Wtsv0z\
    GP///////////wEgAQohCgItNhIbCAISDPWljvGMM9jx7paXMxj///////////8B
    """

    // MARK: Applications — the Recents row

    @Test("Every application map entry decodes through its wrapper")
    func decodesApplications() {
        #expect(FrecencyProto.applications(base64: blob).count == 3)
    }

    /// The account's most-launched activity by a wide margin, and the values the
    /// reference client's own Recents row put first.
    @Test("Use counts and scores match the capture")
    func countsAndScores() throws {
        let byID = Dictionary(
            FrecencyProto.applications(base64: blob).map { ($0.key.description, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let watch = try #require(byID["880218394199220334"])
        #expect(watch.totalUses == 106)
        #expect(watch.score == 1000)

        let wordle = try #require(byID["1211781489931452447"])
        #expect(wordle.totalUses == 27)
        #expect(wordle.score == 1000)

        // Three launches scoring 70 where three launches elsewhere score 300:
        // the score carries time decay, so it is read rather than derived.
        let quote = try #require(byID["949479338275913799"])
        #expect(quote.totalUses == 3)
        #expect(quote.score == 70)
    }

    /// `recent_uses` is a packed repeated **varint**, not the packed `fixed64`
    /// every id list in `PreloadedUserSettings` uses. Read as fixed64 the
    /// timestamps come out as garbage on any length that happens to divide by
    /// eight.
    @Test("recent_uses decodes as packed varints, in milliseconds")
    func recentUsesAreMilliseconds() throws {
        let byID = Dictionary(
            FrecencyProto.applications(base64: blob).map { ($0.key.description, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let watch = try #require(byID["880218394199220334"])
        let last = try #require(watch.lastUsedAt)
        // 1788366506126 ms. Read as seconds it would land in the year 58,000;
        // read as fixed64 it would not land anywhere.
        #expect(abs(last.timeIntervalSince1970 - 1_788_366_506.126) < 0.001)

        let wordle = try #require(byID["1211781489931452447"])
        let wordleLast = try #require(wordle.lastUsedAt)
        #expect(wordleLast < last)
    }

    // MARK: Commands — the Frequently Used section

    /// Field 7 keys are **command** ids, and they resolve against the command
    /// index: `count`, `help`, `ping`, `wordle`, `avatar` — which is the list
    /// Discord's own Frequently Used section drew in the capture's screenshot.
    @Test("Command frecency decodes, keyed by command id")
    func decodesCommands() throws {
        let entries = FrecencyProto.commands(base64: blob)
        #expect(entries.count == 6)

        let byID = Dictionary(entries.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        // esmBot's `/count`, the most recently used chat-input command on the
        // account and the first row of the captured Frequently Used list.
        let count = try #require(byID["991195178100592674"])
        #expect(count.totalUses == 4)
        #expect(abs((count.lastUsedAt ?? .distantPast).timeIntervalSince1970 - 1_786_984_055.944) < 0.001)

        // `/wordle`, which the capture ran again a few seconds later.
        #expect(byID["1331353749247234139"]?.totalUses == 3)
    }

    /// **Discord's own built-in commands are keyed negative.** The capture has
    /// an entry for `-6`. A reader that insisted on parsing a snowflake out of
    /// the key would drop it — harmlessly here, because nothing resolves it, but
    /// the key type is what makes that a decision rather than an accident.
    @Test("A negative built-in command id survives the read")
    func keepsNegativeBuiltInIDs() {
        #expect(FrecencyProto.commands(base64: blob).contains { $0.key == "-6" })
    }

    // MARK: Failure

    /// Garbage in, empty out. The rail-goes-blank failure `ProtobufReader`
    /// exists to prevent applies here too: one bad byte must cost the Recents
    /// row, never the launcher.
    @Test("Malformed input yields no entries rather than throwing")
    func malformedInputIsEmpty() {
        #expect(FrecencyProto.applications(base64: "not base64 at all!!").isEmpty)
        #expect(FrecencyProto.applications(base64: "").isEmpty)
        #expect(FrecencyProto.applications(base64: "SgUKAwoBAQ==").isEmpty)
        #expect(FrecencyProto.commands(base64: "SgUKAwoBAQ==").isEmpty)
    }

    /// The map lives one level below the field, and a decoder that reads the
    /// wrapper *as* an entry answers nothing at all. This is the shape the old
    /// fixture had, kept as a test so the regression cannot come back quietly.
    @Test("A map entry written without its wrapper decodes to nothing")
    func rejectsUnwrappedEntries() {
        // Field 9 carrying a bare `{1: key, 2: item}` — one level too shallow.
        let unwrapped = "SjkKEjk0OTQ3OTMzODI3NTkxMzc5ORIjCAMSEubB3K/9M9/Lk4OBNN/Lk4OBNBj/"
            + "//////////8BIEY="
        #expect(FrecencyProto.applications(base64: unwrapped).isEmpty)
    }

    // MARK: Favourite GIFs

    /// Field 2, in the same wrapper-then-map shape the frecency tables use.
    /// Both entries are the capture's own — one Tenor (`format: 2`, an `.mp4`
    /// rendition) and one Discord attachment (`format: 1`) — with their orders
    /// deliberately out of sequence.
    private let gifs = """
    Eo0ECpoCCmNodHRwczovL3Rlbm9yLmNvbS92aWV3L2NyYWlnLWZlZGVyaWdoaS1mZWRlcmlnaGkt\
    cGFya291ci1wYXJrb3VyLWFwcGxlLXJ1bi1naWYtMTQ1ODc4OTU1MDQ5MTQ0NTQ0MzUSsgEIAhKl\
    AWh0dHBzOi8vaW1hZ2VzLWV4dC0xLmRpc2NvcmRhcHAubmV0L2V4dGVybmFsLzcyM2pFWDZHSXhj\
    SVMtckVGLUZSTzRUdzhBTU14Mmo4R0RvZlN6UFNxWXcvaHR0cHMvbWVkaWEudGVub3IuY29tL3lu\
    S2RxX2J4bDZNQUFBUG8vY3JhaWctZmVkZXJpZ2hpLWZlZGVyaWdoaS1wYXJrb3VyLm1wNBjyAyCa\
    AigNCu0BCmBodHRwczovL2Nkbi5kaXNjb3JkYXBwLmNvbS9hdHRhY2htZW50cy8xNDA1OTg4Nzgx\
    OTM2NDgwMzk3LzE0MDYwMDAwNDIwNTMyMTAzMzQvYXR0YWNobWVudC0xMC5naWYSiAEIARJ8aHR0\
    cHM6Ly9tZWRpYS5kaXNjb3JkYXBwLm5ldC9hdHRhY2htZW50cy8xNDA1OTg4NzgxOTM2NDgwMzk3\
    LzE0MDYwMDAwNDIwNTMyMTAzMzQvYXR0YWNobWVudC0xMC5naWY/Zm9ybWF0PXdlYnAmYW5pbWF0\
    ZWQ9dHJ1ZRiABCCABCgJ
    """

    /// **The key is the GIF's own URL and the value is its rendition.** Sending
    /// the *key* is what puts the original in the channel; the `src` is a
    /// proxied preview and posting that would post a different thing.
    @Test("Favourite GIFs decode from field 2 of the frecency blob")
    func decodesFavoriteGIFs() throws {
        let favorites = FrecencyProto.favoriteGIFs(base64: gifs)
        #expect(favorites.count == 2)

        let attachment = try #require(favorites.last)
        #expect(attachment.url.absoluteString.hasSuffix("attachment-10.gif"))
        #expect(attachment.previewURL?.absoluteString.contains("animated=true") == true)
        #expect(attachment.width == 512)
        #expect(attachment.height == 512)
    }

    /// **`order` is an insertion counter, and the newest goes first.** The
    /// captured account's eighteen favourites run 1 through 18 with no gaps, and
    /// Discord draws the highest at the top — so the fixture's entries, stored
    /// 13 then 9, must come back 13 then 9. Sorting the other way put the
    /// reader's oldest favourite at the top of the grid.
    @Test("Favourites come back newest first")
    func sortsFavoritesNewestFirst() throws {
        let names = FrecencyProto.favoriteGIFs(base64: gifs).map(\.url.absoluteString)
        #expect(names.first?.contains("tenor.com") == true)       // order 13
        #expect(names.last?.contains("attachment-10") == true)    // order 9
    }

    /// The `https` check on the key is the whole safety net against a field
    /// number that has moved: a wrong one yields nothing rather than the
    /// plausible nonsense a protobuf otherwise answers with.
    @Test("A blob with no favourites yields none rather than nonsense")
    func favoritesFailClosed() {
        #expect(FrecencyProto.favoriteGIFs(base64: blob).isEmpty)
        #expect(FrecencyProto.favoriteGIFs(base64: "not base64 at all!!").isEmpty)
    }
}

// MARK: - Writing a favourite back

/// The round trip that `setFavorite` depends on.
///
/// **A writer is what turns a decode bug into data loss**, so this holds the two
/// properties that matter: an entry this client did not fully parse survives
/// re-serialisation byte for byte, and removing one really does produce a
/// smaller map — which is the only way an unfavourite can be expressed at all.
@Suite("Favourite GIF round trip")
struct FavoriteGIFRoundTripTests {

    /// One map entry carrying a field this reader knows nothing about.
    ///
    /// Field 9 is not in `GIFField`, and it is here precisely because it is not:
    /// an entry rebuilt from the five understood fields would drop it, and every
    /// favourite the account has would lose it the first time somebody starred a
    /// new one.
    private func blob(withUnknownField: Bool) -> String {
        var value = ProtobufWriter()
        value.varint(field: 1, 2)
        value.string(field: 2, "https://media.example.invalid/one.mp4")
        value.varint(field: 3, 498)
        value.varint(field: 4, 282)
        value.varint(field: 5, 13)
        if withUnknownField { value.string(field: 9, "something this client cannot read") }

        var entry = ProtobufWriter()
        entry.string(field: 1, "https://tenor.example.invalid/view/one")
        entry.message(field: 2, value.data)

        var second = ProtobufWriter()
        second.varint(field: 1, 1)
        second.string(field: 2, "https://media.example.invalid/two.gif")
        second.varint(field: 5, 7)
        var secondEntry = ProtobufWriter()
        secondEntry.string(field: 1, "https://tenor.example.invalid/view/two")
        secondEntry.message(field: 2, second.data)

        var map = ProtobufWriter()
        map.message(field: 1, entry.data)
        map.message(field: 1, secondEntry.data)
        var top = ProtobufWriter()
        top.message(field: 2, map.data)
        return top.base64
    }

    @Test("An entry this client cannot fully read survives a rewrite")
    func preservesUnknownFields() {
        let original = blob(withUnknownField: true)
        let entries = FrecencyProto.favoriteGIFEntries(base64: original)
        #expect(entries.count == 2)
        // Re-emitted untouched, which is what makes the rewrite safe.
        #expect(FrecencyProto.encodeFavoriteGIFs(entries) == original)
    }

    @Test("Removing one produces a strictly smaller map")
    func removalShrinks() {
        // The whole reason the field is replaced rather than merged: a map
        // merges by key and has no way to say "this one is gone".
        let entries = FrecencyProto.favoriteGIFEntries(base64: blob(withUnknownField: false))
        let kept = entries.filter { $0.key != "https://tenor.example.invalid/view/one" }
        let before = Data(base64Encoded: FrecencyProto.encodeFavoriteGIFs(entries))?.count ?? 0
        let after = Data(base64Encoded: FrecencyProto.encodeFavoriteGIFs(kept))?.count ?? 0
        #expect(after < before)
        #expect(FrecencyProto.favoriteGIFs(base64: FrecencyProto.encodeFavoriteGIFs(kept)).count == 1)
    }

    @Test("A new entry reads back as the GIF that was starred")
    func newEntryRoundTrips() {
        let gif = GIF(
            url: URL(string: "https://tenor.example.invalid/view/three")!,
            previewURL: URL(string: "https://media.example.invalid/three.mp4"),
            width: 400,
            height: 300
        )
        var entries = FrecencyProto.favoriteGIFEntries(base64: blob(withUnknownField: false))
        entries.append(FrecencyProto.favoriteEntry(for: gif, order: 14))
        let read = FrecencyProto.favoriteGIFs(base64: FrecencyProto.encodeFavoriteGIFs(entries))
        // Highest order first — the newest favourite leads the grid.
        #expect(read.first?.url == gif.url)
        #expect(read.first?.previewURL == gif.previewURL)
        #expect(read.first?.width == 400)
        #expect(read.first?.height == 300)
    }
}

// MARK: - Servers and channels — what orders the quick switcher

/// Field 12 (`guild_and_channel_frecency`), the table the switcher ranks on.
///
/// **Five real map entries, wrapper intact, out of `quick switcher.har`.** Its
/// key is a `fixed64` where fields 7 and 9 use a string, which is the one thing
/// about this table that cannot be guessed — read with a string key it decodes
/// to a hundred entries of mojibake on a blob that is perfectly well formed.
/// The first key is a guild the same capture's `quests/decision` call lists as
/// visible; the rest are channels.
@Suite("Navigation frecency")
struct NavigationFrecencyTests {

    private let blob = """
    YpwDClkJbwDCQrCRihMSTggTEjyq1+vjhzTJ2OvjhzTm2evjhzSI2+vjhzSw3OvjhzTj3evjhzSF3+vjhzSz\
    mO3jhzTmr5DkhzSn5/flhzQY////////////ASDoBwpZCQIAhEkMBfMFEk4IGxI88b6Q5Ic0jqSR5Ic0mdWT\
    5Ic0vaSd5Ic03te95Ic0hq/r5Ic0hq/r5Ic0tfL35Yc02ZW25oc0jb6F54c0GP///////////wEgygcKWgkk\
    EID+Ny01FRJPCLQEEjyB5ufjhzTMseXkhzTMseXkhzS+h+fkhzS+h+fkhzSk0PHlhzSrtoDnhzTDhIbnhzTj\
    ha3nhzSEqPbnhzQY////////////ASCsBwpaCfLSFC03LTUVEk8IugUSPOrkls+HNIHm5+OHNNPe7eOHNPqi\
    9OOHNIfF5OSHNM3D8eWHNKu2gOeHNMOEhueHNOOFreeHNISo9ueHNBj///////////8BIPAGCiwJeACET1jA\
    Vw8SIQgDEhLQ497jhzTyj9/jhzTriPLjhzQY////////////AQ==
    """

    @Test("Every map entry decodes through its wrapper")
    func decodesEntries() {
        #expect(FrecencyProto.guildsAndChannels(base64: blob).count == 5)
    }

    /// The account's most-used place in the capture, and a guild rather than a
    /// channel — which is the fact that says this one table holds both.
    @Test("Scores and use counts match the capture")
    func scoresMatchTheCapture() throws {
        let byKey = Dictionary(
            FrecencyProto.guildsAndChannels(base64: blob).map { ($0.key, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let guild = try #require(byKey[1_408_098_019_726_983_279])
        #expect(guild.score == 1000)
        #expect(guild.totalUses == 19)

        let busiest = try #require(byKey[1_520_000_000_000_000_001])
        #expect(busiest.score == 880)
        #expect(busiest.totalUses == 698)
    }

    /// The tie-break for "previous channels". A stored score with no timestamp
    /// would order the list by how often rather than how recently.
    @Test("The last visit comes back as a date")
    func lastUsedIsRead() throws {
        let byKey = Dictionary(
            FrecencyProto.guildsAndChannels(base64: blob).map { ($0.key, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let entry = try #require(byKey[1_520_000_000_000_000_001])
        let last = try #require(entry.lastUsedAt)
        // September 2026, which is when the capture was taken.
        #expect(last > Date(timeIntervalSince1970: 1_757_000_000))
        #expect(last < Date(timeIntervalSince1970: 1_790_000_000))
    }

    /// A place with no uses is still an entry, and the caller decides whether a
    /// zero score is worth a row. Nothing is filtered out down here.
    @Test("A zero score is a real answer, not an absence")
    func zeroScoreSurvives() throws {
        let byKey = Dictionary(
            FrecencyProto.guildsAndChannels(base64: blob).map { ($0.key, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let cold = try #require(byKey[1_105_563_719_066_452_088])
        #expect(cold.score == 0)
        #expect(cold.totalUses == 3)
    }

    /// The depth guard the whole file exists for. Read one level too shallow —
    /// each map entry written directly as field 12 — the decoder must answer
    /// nothing rather than plausible nonsense.
    @Test("The wrong framing decodes to nothing")
    func wrongFramingIsEmpty() throws {
        let data = try #require(Data(base64Encoded: blob.filter { !$0.isWhitespace }))
        // Strip the outer field-12 wrapper's own tag and length, leaving the map
        // entries at the top level — which is the mistake that shipped once.
        let shallow = data.dropFirst(3)
        #expect(FrecencyProto.guildsAndChannels(base64: shallow.base64EncodedString()).isEmpty)
    }

    /// A string key on this map is exactly the wrong guess this table invites,
    /// and it has to cost the entry rather than yield a mangled one.
    @Test("Read with a string key the map yields nothing")
    func stringKeysFindNothing() {
        #expect(FrecencyProto.applications(base64: blob).isEmpty)
        #expect(FrecencyProto.commands(base64: blob).isEmpty)
    }
}
