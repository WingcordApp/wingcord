import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// The rail's arrangement going back to Discord, against the two writes its
/// own client made in `rearranging servers.har` (2026-09-30): the account's
/// whole folder list, then the same list after one server was dropped on
/// another.
@Suite("Guild folders proto")
struct GuildFoldersProtoTests {

    /// The first `PATCH /users/@me/settings-proto/1`, verbatim.
    private static let before = """
        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
        lOKrCAoABM6ItCYIAABA2sm7YQgKAAwcICqwCw==
        """

    /// The second, ten seconds later: `1545395808394106251` dropped on
    /// `240031172428247949`, which made folder `49707895` of the two.
    private static let after = """
        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
        """

    private static func bytes(_ base64: String) -> Data {
        Data(base64Encoded: base64, options: .ignoreUnknownCharacters) ?? Data()
    }

    private static func setting(_ base64: String) throws -> GuildFolderSettings {
        try #require(UserSettingsProto.guildFolders(in: bytes(base64)))
    }

    @Test("A folder list goes back byte for byte as Discord's client wrote it")
    func roundTrip() throws {
        let decoded = try Self.setting(Self.before)
        // Seven folders — one of them holding a single server — and 72 loose.
        #expect(decoded.folders.count == 79)
        #expect(decoded.folders.count(where: \.isRealFolder) == 7)
        #expect(decoded.guildPositions.count == 96)
        let encoded = UserSettingsProto.encodeGuildFolders(decoded.folders, guildPositions: decoded.guildPositions)
        #expect(Self.bytes(encoded) == Self.bytes(Self.before))
    }

    /// **The combine, end to end**: Discord's rule applied to the first write
    /// produces the second, down to the byte — the new folder where the server
    /// dropped on was, that server first, no name and no colour, and
    /// `guild_positions` untouched.
    @Test("Dropping one server on another writes what Discord's client wrote")
    func combineMatchesTheCapture() throws {
        var setting = try Self.setting(Self.before)
        let changed = GuildArrangement.combine(
            GuildID(rawValue: 1_545_395_808_394_106_251),
            with: .guild(GuildID(rawValue: 240_031_172_428_247_949)),
            in: &setting.folders,
            random: { 49_707_895 }
        )
        #expect(changed)
        let encoded = UserSettingsProto.encodeGuildFolders(setting.folders, guildPositions: setting.guildPositions)
        #expect(Self.bytes(encoded) == Self.bytes(Self.after))
    }

    @Test("A settings update that carries the folders is read; one that does not says nothing")
    func settingsUpdate() throws {
        func update(_ proto: String) throws -> GatewayUpdate? {
            let json = #"{"op":0,"s":9,"t":"USER_SETTINGS_PROTO_UPDATE","d":{"settings":{"type":1,"proto":"\#(proto)"},"partial":true}}"#
            let frame = try JSONDecoder().decode(GatewayFrame.self, from: Data(json.utf8))
            return GatewayUpdate(frame.payload)
        }
        let compact = Self.before.filter { !$0.isWhitespace }
        guard case .userSettingsChanged(let setting?, _, _)? = try update(compact) else {
            Issue.record("the folders should have been read")
            return
        }
        #expect(setting.folders.count == 79)
        // The inbox tab alone — `EgQIBxAB`, captured — changes nothing here.
        #expect(try update("EgQIBxAB") == nil)
    }
}
