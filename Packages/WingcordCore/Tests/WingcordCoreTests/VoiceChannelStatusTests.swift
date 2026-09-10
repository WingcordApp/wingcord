import Foundation
import Testing
@testable import WingcordCore

/// Splitting a voice channel's label into what a row draws.
///
/// **A status is not markdown and is deliberately not parsed as it.** Discord
/// renders no emphasis, no links and no mentions in one — only emoji — so this
/// is a single pass over the bytes rather than a tree. The sidebar builds one of
/// these per voice channel per rebuild, and a five-hundred-channel server is
/// where the difference stops being theoretical.
@Suite("Voice channel status")
struct VoiceChannelStatusTests {

    @Test("A plain label is one run and scans nothing")
    func plain() {
        #expect(VoiceChannelStatus.runs("NA COMP 6+") == [.text("NA COMP 6+")])
        #expect(VoiceChannelStatus.runs("").isEmpty)
    }

    @Test("A custom emoji comes out as itself, with the text either side kept")
    func customEmoji() {
        let runs = VoiceChannelStatus.runs("<:eu:123> comp <a:blob:456> 18+")
        #expect(runs == [
            .emoji(EmojiRef(id: EmojiID(rawValue: 123), name: "eu")),
            .text(" comp "),
            .emoji(EmojiRef(id: EmojiID(rawValue: 456), name: "blob", isAnimated: true)),
            .text(" 18+"),
        ])
    }

    /// A Unicode emoji is a character like any other. Splitting it out would
    /// mean asking the CDN for a picture of something the font already draws.
    @Test("A Unicode emoji stays in the text")
    func unicodeEmojiIsText() {
        #expect(VoiceChannelStatus.runs("chill comp 🟢 trust") == [.text("chill comp 🟢 trust")])
    }

    /// **A bracket that opens nothing is text**, and this is the case that
    /// matters: people put `<3` and `<-- here` in these, and a scanner that
    /// swallowed everything to the next `>` would eat the rest of the line.
    @Test("A bracket that is not an emoji is kept verbatim")
    func brokenMarkup() {
        #expect(VoiceChannelStatus.runs("<3 duo") == [.text("<3 duo")])
        #expect(VoiceChannelStatus.runs("a < b > c") == [.text("a < b > c")])
        #expect(VoiceChannelStatus.runs("<:noid:>") == [.text("<:noid:>")])
        #expect(VoiceChannelStatus.runs("<:name:notdigits>") == [.text("<:name:notdigits>")])
        #expect(VoiceChannelStatus.runs("<@1234>") == [.text("<@1234>")])
    }

    @Test("An unterminated bracket does not eat the rest of the line")
    func unterminated() {
        #expect(VoiceChannelStatus.runs("push <:eu:1 now") == [.text("push <:eu:1 now")])
    }

    @Test("A label that is nothing but one emoji is one run")
    func emojiOnly() {
        #expect(
            VoiceChannelStatus.runs("<:eu:1>")
                == [.emoji(EmojiRef(id: EmojiID(rawValue: 1), name: "eu"))]
        )
    }

    /// Applying a patch is what keeps three separate events from overwriting
    /// each other's fields — see `VoiceChannelPatch`.
    @Test("A patch touches only what its event mentioned")
    func patching() {
        var info = VoiceChannelInfo(status: "here", sessionStartedAt: .distantPast)
        info.apply(VoiceChannelPatch(status: .some("there")))
        #expect(info.status == "there")
        #expect(info.sessionStartedAt == .distantPast)

        info.apply(VoiceChannelPatch(sessionStartedAt: .some(nil)))
        #expect(info.status == "there")
        #expect(info.sessionStartedAt == nil)

        info.apply(VoiceChannelPatch())
        #expect(info.status == "there")
    }
}
