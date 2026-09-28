import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// The settings blob READY carries, and the field numbering it is read with.
///
/// **The numbering in `UserSettingsProto` was taken off a live READY, and this
/// suite pins it.** A protobuf parsed with wrong field numbers does not throw —
/// it produces plausible nonsense — so the only thing standing between "the
/// rail is ordered" and "the rail is ordered by something meaningless" is that
/// these numbers stay what the capture said they were.
///
/// The fixtures are built here rather than pasted in as a captured blob: the
/// real one carries an account's guild ids and folder names, and a test does not
/// need somebody's server list to prove a decoder reads a wire format.
///
/// Verified against that capture on 2026-08-26 — 97 `guild_positions`, seven
/// real folders, seventy-one loose guilds — before this was written.
struct UserSettingsProtoTests {

    // MARK: Building

    private static func varint(_ value: UInt64) -> [UInt8] {
        var value = value
        var out: [UInt8] = []
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            out.append(byte)
        } while value != 0
        return out
    }

    private static func key(_ field: Int, _ wire: Int) -> [UInt8] {
        varint(UInt64(field << 3 | wire))
    }

    private static func fixed64(_ value: UInt64) -> [UInt8] {
        (0..<8).map { UInt8((value >> (8 * UInt64($0))) & 0xFF) }
    }

    /// A length-delimited field.
    private static func message(_ field: Int, _ body: [UInt8]) -> [UInt8] {
        key(field, 2) + varint(UInt64(body.count)) + body
    }

    /// A `google.protobuf.*Value` wrapper: a message whose only field is 1.
    private static func wrappedVarint(_ field: Int, _ value: UInt64) -> [UInt8] {
        message(field, key(1, 0) + varint(value))
    }

    private static func wrappedString(_ field: Int, _ value: String) -> [UInt8] {
        let bytes = Array(value.utf8)
        return message(field, message(1, bytes))
    }

    private static func packedIDs(_ field: Int, _ ids: [UInt64]) -> [UInt8] {
        message(field, ids.flatMap(fixed64))
    }

    /// One folder, in the shape the capture showed.
    private static func folder(
        ids: [UInt64],
        id: UInt64? = nil,
        name: String? = nil,
        color: UInt64? = nil
    ) -> [UInt8] {
        var body = packedIDs(1, ids)
        if let id { body += wrappedVarint(2, id) }
        if let name { body += wrappedString(3, name) }
        if let color { body += wrappedVarint(4, color) }
        return message(1, body)
    }

    private static func blob(
        status: String? = nil,
        folders: [[UInt8]] = [],
        positions: [UInt64] = []
    ) -> Data {
        var out: [UInt8] = []
        if let status {
            out += message(11, wrappedString(1, status))
        }
        var foldersBody: [UInt8] = folders.flatMap { $0 }
        if !positions.isEmpty { foldersBody += packedIDs(2, positions) }
        if !foldersBody.isEmpty { out += message(14, foldersBody) }
        return Data(out)
    }

    // MARK: Tests

    @Test("A named folder keeps its name, colour, id and members")
    func namedFolder() {
        let data = Self.blob(folders: [
            Self.folder(ids: [111, 222, 333], id: 42, name: "Discord Mods", color: 15277667)
        ])
        let settings = UserSettingsProto.decode(data)

        #expect(settings.folders.count == 1)
        let folder = settings.folders[0]
        #expect(folder.name == "Discord Mods")
        #expect(folder.id == 42)
        #expect(folder.colorValue == 15277667)
        #expect(folder.guildIDs.map(\.rawValue) == [111, 222, 333])
    }

    @Test("Guild ids are packed fixed64, little-endian, in order")
    func packedIdentifiers() {
        // A real snowflake, so a byte-order mistake cannot hide inside a small
        // number: reversed, this one is astronomically large.
        let snowflake: UInt64 = 1389844227072146916
        let data = Self.blob(folders: [Self.folder(ids: [snowflake])])
        let settings = UserSettingsProto.decode(data)
        #expect(settings.folders.first?.guildIDs.first?.rawValue == snowflake)
    }

    @Test("A loose guild arrives as a one-member entry, not as a folder")
    func looseGuildIsNotAFolder() {
        // This is how the settings represent a guild sitting on its own in the
        // rail, and drawing it as a folder would put every unfoldered server in
        // a container nobody created.
        let data = Self.blob(folders: [Self.folder(ids: [999])])
        let settings = UserSettingsProto.decode(data)
        #expect(settings.folders.first?.isRealFolder == false)
    }

    @Test("Guild positions are read, and separately from the folders")
    func guildPositions() {
        let data = Self.blob(
            folders: [Self.folder(ids: [111], id: 7)],
            positions: [111, 222, 333]
        )
        let settings = UserSettingsProto.decode(data)
        #expect(settings.guildPositions.map(\.rawValue) == [111, 222, 333])
        #expect(settings.folders.count == 1)
    }

    @Test("Status comes out of its wrapper")
    func status() {
        #expect(UserSettingsProto.decode(Self.blob(status: "dnd")).status == .doNotDisturb)
        #expect(UserSettingsProto.decode(Self.blob(status: "idle")).status == .idle)
    }

    @Test("An unknown status falls back rather than failing the whole blob")
    func unknownStatus() {
        let data = Self.blob(status: "hyperfocused", folders: [Self.folder(ids: [111])])
        let settings = UserSettingsProto.decode(data)
        #expect(settings.status == .online)
        // And crucially, the folders still arrived.
        #expect(settings.folders.count == 1)
    }

    @Test("Fields this client does not know are skipped, not fatal")
    func unknownFieldsAreSkipped() {
        // Discord adds to this message continually. An unrecognised field must
        // cost nothing — the failure this must never have is "one new field and
        // the account has no servers".
        var out: [UInt8] = Self.key(9, 0) + Self.varint(1234)
        out += Self.message(77, Array("something new".utf8))
        out += Self.key(88, 1) + Self.fixed64(999)
        out += Self.key(99, 5) + [1, 2, 3, 4]
        out += Self.message(14, Self.folder(ids: [111], name: "Kept"))
        let settings = UserSettingsProto.decode(Data(out))
        #expect(settings.folders.first?.name == "Kept")
    }

    @Test("Malformed input yields empty settings rather than crashing")
    func malformedInput() {
        // A truncated length prefix, which is what a half-written blob looks
        // like. It must terminate.
        let data = Data([0x72, 0xFF, 0xFF, 0xFF, 0x7F])
        let settings = UserSettingsProto.decode(data)
        #expect(settings.folders.isEmpty)
        #expect(settings.status == .online)
    }

    @Test("Base64 that is not base64 is refused, not guessed at")
    func badBase64() {
        #expect(UserSettingsProto.decode(base64: "not base64 !!!") == nil)
    }
}
