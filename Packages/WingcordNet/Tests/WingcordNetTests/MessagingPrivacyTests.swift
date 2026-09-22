import Foundation
import Testing
@testable import WingcordCore
@testable import WingcordNet

/// The Messaging Permissions page, on the wire.
///
/// **The fixtures are captured bodies, not constructed ones.** `INVARIANTS.md`
/// §2.6: a test input that does not look like the caller's guards the bug. These
/// two are verbatim `PATCH /users/@me/settings-proto/1` bodies out of
/// `messaging permissions.har` (2026-09-22), taken while one control at a time
/// was moved with the Network tab open — so what they pin is what Discord
/// actually sent, including the parts this client does not read.
@Suite("Messaging permissions")
struct MessagingPrivacyTests {

    /// The first captured PATCH. `text_and_images` with the content filters at
    /// SHOW / BLUR / BLOCK and the spam filter unwritten.
    private static let firstPatch = """
        MnkqEzE0OTQ3MDUwOTYwMjg1ODYwNjRKAggBUgIIAVoCCAFiAggBagIIAXICCAF6AIIBAggBigEAmgECCAKiAQ\
        CqAQCyAQDKARMxMDU5MTM5MzQ1ODI0NjI4NzQ2ygESNTg3MzU1MzAxMDgzMzQ5MDAy6gEGCAEQAhgD
        """

    /// The tenth, after the spam filter was set to "Filter all spam".
    private static let spamPatch = """
        Mn8qEzE0OTQ3MDUwOTYwMjg1ODYwNjRKAggBUgIIAVoCCAFiAggBagIIAXICCAF6AIIBAggBigEAmgECCAKiAQ\
        CqAQCyAQC6AQDKARMxMDU5MTM5MzQ1ODI0NjI4NzQ2ygESNTg3MzU1MzAxMDgzMzQ5MDAy2AED6gEGCAEQAxgD
        """

    private func decode(_ base64: String) -> (
        privacy: MessagingPrivacy, textRaw: Data?, privacyRaw: Data?
    ) {
        MessagingPrivacyProto.decode(Data(base64Encoded: base64) ?? Data())
    }

    // MARK: What the capture says

    @Test("The three rows of a filter are read in Discord's order, not the page's")
    func filterOrderIsTheWiresNotThePages() {
        // **This is the trap the whole file exists for.** The page reads
        // friends / others / servers top to bottom; the wire is
        // servers / friends / others. The captured message is `08 01 10 02 18
        // 03`, and the account it came from had servers on Show.
        let value = decode(Self.firstPatch).privacy
        #expect(value.explicit.serverChannels == .show)
        #expect(value.explicit.friendDirectMessages == .blur)
        #expect(value.explicit.otherDirectMessages == .block)
    }

    @Test("A category nobody has answered stays unset")
    func untouchedCategoriesAreUnset() {
        // Only `explicit_content_settings` is in that body. Reading a default
        // into the other two and writing it back is what silently changes a
        // setting nobody touched.
        let value = decode(Self.firstPatch).privacy
        #expect(value.gore == ContentFilter())
        #expect(value.selfHarm == ContentFilter())
    }

    @Test("The spam filter is a bare enum, and its names describe whose spam")
    func spamFilter() {
        #expect(decode(Self.firstPatch).privacy.spamFilter == .unset)
        // `FRIENDS_AND_NON_FRIENDS` is the strictest, not the loosest.
        #expect(decode(Self.spamPatch).privacy.spamFilter == .everyone)
        #expect(DMSpamFilter.everyone.title == "Filter all spam")
    }

    @Test("A BoolValue's emptiness is its value")
    func emptyBoolIsFalse() {
        // `view_nsfw_guilds` is `aqEBAA` / `qgEA` in that body — field 20, length
        // zero. A decoder that required a payload reports `true` for an account
        // that switched the thing off.
        #expect(!decode(Self.firstPatch).privacy.allowsAgeRestrictedGuilds)
    }

    // MARK: Writing

    @Test("A write keeps every byte it did not come for")
    func writePreservesTheRest() throws {
        let (_, textRaw, _) = decode(Self.firstPatch)
        let raw = try #require(textRaw)
        let patch = MessagingPrivacyProto.patch(applying: .spamFilter(.nonFriends), to: raw)
        let back = decode(patch).privacy

        #expect(back.spamFilter == .nonFriends)
        // Everything else is the bytes it arrived as. This is the whole safety
        // argument: `text_and_images` carries the reader's collapsed picker
        // sections and their keyword filters, and a writer that re-serialised
        // what it understood would delete both.
        #expect(back.explicit.serverChannels == .show)
        #expect(back.explicit.friendDirectMessages == .blur)
        #expect(back.explicit.otherDirectMessages == .block)
    }

    @Test("One row of a filter moves without clearing the other two")
    func oneSurfaceAtATime() throws {
        let (_, textRaw, _) = decode(Self.firstPatch)
        let raw = try #require(textRaw)
        let patch = MessagingPrivacyProto.patch(
            applying: .contentFilter(.explicit, .friendDirectMessages, .show),
            to: raw
        )
        let back = decode(patch).privacy
        #expect(back.explicit.friendDirectMessages == .show)
        #expect(back.explicit.serverChannels == .show)
        #expect(back.explicit.otherDirectMessages == .block)
    }

    @Test("A restriction is written inverted, and it round-trips")
    func restrictionsInvert() {
        // Every one of these is a *restriction* on the wire and a permission on
        // the page. A client that wrote them straight would shut off the direct
        // messages of anybody who opened this pane.
        for allowed in [true, false] {
            let patch = MessagingPrivacyProto.patch(
                applying: .directMessagesByDefault(allowed), to: Data()
            )
            #expect(decode(patch).privacy.allowsDirectMessagesByDefault == allowed)

            let requests = MessagingPrivacyProto.patch(
                applying: .messageRequestsByDefault(allowed), to: Data()
            )
            #expect(decode(requests).privacy.filtersMessageRequestsByDefault == allowed)

            let notes = MessagingPrivacyProto.patch(
                applying: .friendRequestNotes(allowed), to: Data()
            )
            #expect(decode(notes).privacy.showsFriendRequestNotes == allowed)
        }
    }

    @Test("Friend sources are a bitmask whose low bit is unused")
    func friendSourceBits() {
        // 2, 4, 8 — read out of the bundle. A client that assumed 1, 2, 4 would
        // turn on a source nobody asked for, and "everyone" is the bit that
        // admits somebody you share nothing with.
        #expect(FriendSourceFlags.all.rawValue == 14)
        let patch = MessagingPrivacyProto.patch(
            applying: .friendSources([.mutualFriends, .mutualGuilds]), to: Data()
        )
        let back = decode(patch).privacy.friendSources
        #expect(back == [.mutualFriends, .mutualGuilds])
        #expect(!back.contains(.everyone))
    }

    @Test("A change goes into the message it belongs to")
    func changesAreRoutedToTheirOwnMessage() {
        // A content filter lives in `text_and_images` and a friend source in
        // `privacy`. Spliced into the wrong one, a write replaces the other
        // message with a single field — which is a page that wipes somebody's
        // restricted-server lists when they blur a picture.
        let text = MessagingPrivacyProto.patch(applying: .spamFilter(.off), to: Data())
        #expect(decode(text).textRaw != nil)
        #expect(decode(text).privacyRaw == nil)

        let privacy = MessagingPrivacyProto.patch(
            applying: .friendSources(.all), to: Data()
        )
        #expect(decode(privacy).privacyRaw != nil)
        #expect(decode(privacy).textRaw == nil)
    }

    // MARK: What the page may offer

    @Test("A server channel can be blurred but not blocked")
    func serverChannelsCannotBeBlocked() {
        // Sourced to the running client and to the capture — across eighteen
        // PATCHes the guild field never left SHOW while both direct-message
        // fields were driven through all three values.
        #expect(ContentFilterSurface.serverChannels.options == [.show, .blur])
        #expect(ContentFilterSurface.friendDirectMessages.options.contains(.block))
        #expect(ContentFilterSurface.otherDirectMessages.options.contains(.block))
    }
}
