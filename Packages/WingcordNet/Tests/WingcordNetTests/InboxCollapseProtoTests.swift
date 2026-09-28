import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// The inbox's folded groups in the settings proto: read, and written back
/// with every other byte of every server's settings untouched.
struct InboxCollapseProtoTests {

    /// `ChannelSettings`: the flag, and an icon emoji (field 2) nobody here reads.
    private func channelSettings(collapsed: Bool) -> Data {
        var channel = ProtobufWriter()
        if collapsed { channel.varint(field: 1, 1) }
        channel.message(field: 2, Data([0x08, 0x2A]))
        return channel.data
    }

    private func entry(_ key: UInt64, _ value: Data) -> Data {
        var pair = ProtobufWriter()
        pair.fixed64(field: 1, key)
        pair.message(field: 2, value)
        var outer = ProtobufWriter()
        outer.message(field: 1, pair.data)
        return outer.data
    }

    /// A blob with one server holding one folded channel and a theme choice
    /// (field 13), beside an inbox message (field 2).
    private var blob: Data {
        var guildSettings = entry(7, channelSettings(collapsed: true))
        var theme = ProtobufWriter()
        theme.varint(field: 13, 2)
        guildSettings.append(theme.data)
        var root = ProtobufWriter()
        root.message(field: 2, Data([0x08, 0x07]))
        root.message(field: 3, entry(100, guildSettings))
        return root.data
    }

    @Test("A folded channel is read out of the server's settings")
    func decodes() {
        let settings = UserSettingsProto.decode(blob)
        #expect(settings.inboxCollapse.channels == [ChannelID(rawValue: 7)])
    }

    @Test("Unfolding clears only the flag, and keeps the icon and the theme")
    func unfolds() throws {
        let patch = UserSettingsProto.patchInboxCollapsed(
            [.init(guild: 100, channel: 7, collapsed: false)], in: blob
        )
        let written = try #require(Data(base64Encoded: patch))
        let decoded = UserSettingsProto.decode(written)
        #expect(decoded.inboxCollapse.channels.isEmpty)
        #expect(decoded.serverThemes.overrides[GuildID(rawValue: 100)] != nil)
        // The icon emoji's two bytes are still in there.
        #expect(written.range(of: Data([0x12, 0x02, 0x08, 0x2A])) != nil)
    }

    @Test("Folding a channel in a server with no settings adds the entry")
    func adds() throws {
        let patch = UserSettingsProto.patchInboxCollapsed(
            [.init(guild: 0, channel: 55, collapsed: true)], in: blob
        )
        let decoded = UserSettingsProto.decode(try #require(Data(base64Encoded: patch)))
        #expect(decoded.inboxCollapse.channels == [ChannelID(rawValue: 7), ChannelID(rawValue: 55)])
    }

    @Test("A server's scheduled-events group is its own key")
    func guildEvents() throws {
        let patch = UserSettingsProto.patchInboxCollapsed(
            [.init(guild: 100, channel: UserSettingsProto.guildEventsChannel, collapsed: true)], in: blob
        )
        let decoded = UserSettingsProto.decode(try #require(Data(base64Encoded: patch)))
        #expect(decoded.inboxCollapse.guildEvents == [GuildID(rawValue: 100)])
    }
}
