import Foundation
import Testing
@testable import WingcordCore
@testable import WingcordNet

/// "Sync theme across my devices" on the wire: `appearance.theme` and the
/// gradient preset in `client_theme_settings`, read and written as Discord's
/// descriptors and its picker (`817281.p`) say — every other field of
/// `appearance` kept.
@Suite("Account theme")
struct AccountThemeProtoTests {

    /// `appearance` as an account that picked Sunset in Discord holds it, with
    /// Developer Mode on and the server-theme preference set beside it.
    private static func blob(theme: Int, clientThemeSettings: Data?) -> Data {
        var appearance = ProtobufWriter()
        appearance.varint(field: 1, UInt64(theme))
        appearance.varint(field: 2, 1)
        if let clientThemeSettings { appearance.message(field: 3, clientThemeSettings) }
        appearance.varint(field: 14, 2)
        var blob = ProtobufWriter()
        blob.message(field: 13, appearance.data)
        return blob.data
    }

    private static func preset(_ id: Int?) -> Data {
        var settings = ProtobufWriter()
        if let id {
            var wrapper = ProtobufWriter()
            if id != 0 { wrapper.varint(field: 1, UInt64(id)) }
            settings.message(field: 2, wrapper.data)
        }
        return settings.data
    }

    /// The `appearance` fields other than the theme's, for the splice's
    /// promise.
    private static func neighbours(_ blob: Data) -> [Int: UInt64] {
        var reader = ProtobufReader(blob)
        var found: [Int: UInt64] = [:]
        while let field = reader.next() {
            guard field.number == 13 else { continue }
            var appearance = reader.reader(for: field)
            while let entry = appearance.next() {
                if entry.number == 2 || entry.number == 14 { found[entry.number] = entry.value }
            }
        }
        return found
    }

    @Test("A preset is read with its base; Mint Apple is an empty wrapper")
    func decode() {
        let sunset = SyncedPreferencesProto.decode(Self.blob(theme: 3, clientThemeSettings: Self.preset(8)))
        #expect(sunset.accountTheme == AccountTheme(base: 3, gradientPresetID: 8))
        let mint = SyncedPreferencesProto.decode(Self.blob(theme: 2, clientThemeSettings: Self.preset(0)))
        #expect(mint.accountTheme?.gradientPresetID == 0)
        let plain = SyncedPreferencesProto.decode(Self.blob(theme: 1, clientThemeSettings: Self.preset(nil)))
        #expect(plain.accountTheme == AccountTheme(base: 1))
        #expect(SyncedPreferencesProto.decode(Data()).accountTheme == nil)
    }

    @Test("A Nitro custom theme is noticed, and no preset is taken from it")
    func custom() {
        var custom = ProtobufWriter()
        custom.string(field: 1, "#ff0000")
        var settings = ProtobufWriter()
        settings.message(field: 4, custom.data)
        let theme = SyncedPreferencesProto.decode(Self.blob(theme: 3, clientThemeSettings: settings.data)).accountTheme
        #expect(theme?.hasCustomTheme == true)
        #expect(theme?.gradientPresetID == nil)
    }

    @Test("Writing a theme replaces the base and the client theme settings, and keeps the rest")
    func write() throws {
        let start = Self.blob(theme: 3, clientThemeSettings: Self.preset(8))
        let mint = try #require(Data(base64Encoded: SyncedPreferencesProto.patch(
            applying: .accountTheme(base: AccountTheme.light, gradientPresetID: 0), to: start
        )))
        #expect(SyncedPreferencesProto.decode(mint).accountTheme == AccountTheme(base: 2, gradientPresetID: 0))
        #expect(Self.neighbours(mint) == [2: 1, 14: 2])

        // A house theme: Discord's plain room, its preset gone.
        let plain = try #require(Data(base64Encoded: SyncedPreferencesProto.patch(
            applying: .accountTheme(base: AccountTheme.dark, gradientPresetID: nil), to: mint
        )))
        #expect(SyncedPreferencesProto.decode(plain).accountTheme == AccountTheme(base: 3))
        #expect(Self.neighbours(plain) == [2: 1, 14: 2])
    }
}
