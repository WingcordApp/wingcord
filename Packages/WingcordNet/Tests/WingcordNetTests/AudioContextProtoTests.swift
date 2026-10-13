import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// People's volumes and mutes in the settings proto: read, and written back
/// one entry at a time with every other byte as it came.
struct AudioContextProtoTests {

    /// `AudioContextSetting`, by hand: muted, a volume ×100, a stamp, and a
    /// field 9 this client cannot name.
    private func setting(muted: Bool, volume: Float, stamp: UInt64, extra: Bool = false) -> Data {
        var value = ProtobufWriter()
        if muted { value.varint(field: 1, 1) }
        value.float(field: 2, volume)
        value.fixed64(field: 3, stamp)
        if extra { value.varint(field: 9, 42) }
        return value.data
    }

    private func entry(map: Int, _ key: UInt64, _ value: Data) -> Data {
        var pair = ProtobufWriter()
        pair.fixed64(field: 1, key)
        pair.message(field: 2, value)
        var outer = ProtobufWriter()
        outer.message(field: map, pair.data)
        return outer.data
    }

    /// One muted person at half volume with an unknown field, one stream at
    /// 30, beside the inbox's tab (field 2).
    private var blob: Data {
        var audio = entry(map: 1, 7, setting(muted: true, volume: 50, stamp: 1_000, extra: true))
        audio.append(entry(map: 2, 9, setting(muted: false, volume: 30, stamp: 2_000)))
        var root = ProtobufWriter()
        root.message(field: 2, Data([0x08, 0x07]))
        root.message(field: 16, audio)
        return root.data
    }

    @Test("Volumes and mutes are read for voices and streams, ×100 off the wire")
    func decodes() throws {
        let settings = try #require(AudioContextProto.decode(blob))
        #expect(settings.users[UserID(rawValue: 7)] == .init(isMuted: true, volume: 0.5, modifiedAt: 1_000))
        #expect(settings.streams[UserID(rawValue: 9)] == .init(volume: 0.3, modifiedAt: 2_000))
        #expect(UserSettingsProto.decode(blob).audioContext == settings)
    }

    @Test("A blob without the field says nothing about it")
    func absent() {
        var root = ProtobufWriter()
        root.message(field: 2, Data([0x08, 0x07]))
        #expect(AudioContextProto.decode(root.data) == nil)
    }

    @Test("A changed entry keeps what this client cannot name, and the others go back as they came")
    func changes() throws {
        let patch = AudioContextProto.patch(
            [.init(context: .user, userID: UserID(rawValue: 7), entry: .init(isMuted: false, volume: 0.8, modifiedAt: 3_000))],
            in: blob
        )
        let written = try #require(Data(base64Encoded: patch))
        let settings = try #require(AudioContextProto.decode(written))
        #expect(settings.users[UserID(rawValue: 7)] == .init(volume: 0.8, modifiedAt: 3_000))
        #expect(settings.streams[UserID(rawValue: 9)] == .init(volume: 0.3, modifiedAt: 2_000))
        // Field 9 = 42 is still in the rewritten entry.
        #expect(written.range(of: Data([0x48, 0x2A])) != nil)
        // Only the audio field is sent: the inbox is not in the patch.
        #expect(written.range(of: Data([0x12, 0x02, 0x08, 0x07])) == nil)
    }

    @Test("A removal drops the entry, and a new person is added")
    func removesAndAdds() throws {
        let patch = AudioContextProto.patch([
            .init(context: .stream, userID: UserID(rawValue: 9), entry: nil),
            .init(context: .user, userID: UserID(rawValue: 11), entry: .init(volume: 1.5, modifiedAt: 4_000)),
        ], in: blob)
        let written = try #require(Data(base64Encoded: patch))
        let settings = try #require(AudioContextProto.decode(written))
        #expect(settings.streams.isEmpty)
        #expect(settings.users[UserID(rawValue: 11)] == .init(volume: 1.5, modifiedAt: 4_000))
        #expect(settings.users[UserID(rawValue: 7)]?.isMuted == true)
    }

    @Test("A map past 300 loses its oldest")
    func prunes() throws {
        var audio = Data()
        for index in 1...300 {
            audio.append(entry(map: 1, UInt64(index), setting(muted: true, volume: 100, stamp: UInt64(index))))
        }
        var root = ProtobufWriter()
        root.message(field: 16, audio)
        let patch = AudioContextProto.patch(
            [.init(context: .user, userID: UserID(rawValue: 999), entry: .init(isMuted: true, volume: 1, modifiedAt: 5_000))],
            in: root.data
        )
        let written = try #require(Data(base64Encoded: patch))
        let settings = try #require(AudioContextProto.decode(written))
        #expect(settings.users.count == 300)
        #expect(settings.users[UserID(rawValue: 1)] == nil)
        #expect(settings.users[UserID(rawValue: 999)] != nil)
    }
}
