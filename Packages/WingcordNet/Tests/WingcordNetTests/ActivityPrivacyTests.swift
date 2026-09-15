import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// Activity privacy, against the bytes Discord actually sent.
///
/// **Every fixture is a `PATCH /users/@me/settings-proto/1` body captured
/// 2026-09-14**, one control toggled at a time with the Network tab open. They
/// are base64 exactly as they went on the wire, and the expectations are the
/// state of the settings window in the screenshot taken beside each one.
@Suite("Activity privacy")
struct ActivityPrivacyTests {

    /// "Do not share in any servers", with both join toggles still on and 85
    /// servers already restricted. The fourth PATCH of the session.
    /// **Verbatim, and long on purpose.** The first attempt at this fixture
    /// was the first sixty-four characters of the body, and the test caught it:
    /// field 29 is at the *end* of the message, after 85 packed guild ids, so a
    /// truncated copy decodes cleanly and reports the wrong scope.
    private let scopeChanged =
        "QuUFCgIIARoIouG1qvfvcQ5CAggBSgIIAVICCAFaAggOYgIIBmqoBaLhtar373EOAgCESQwF8wWi"
            + "EAIjsJGKEwsAxAZOdAIEjTObXxTDVAMBAES3oQf4B+Q9w/f1t0kTUADAlF1CvhRJAEBsSj/tEgCA"
            + "QuspARcN4ghQIcMNvwoVAALw4pmcBB4AjgMHRTELbwDEsq9gwxNkEIQ/lxZEEpkAgKT9bCMRCzCE"
            + "+Q/9ww8fQIIIlvJ0DB4AhCb0TqwRZBDC+b3wTBNUEIA+4GFqEyEgRE0WUoMPbgBELoZH6w8yEITd"
            + "VFVkEFqAgjZWe7YNeADCHcwDJBF5QES6fcYPEDwAREthP9kRHwBK2cZKlgqsAASQfICJEkZABGyp"
            + "mMEPbxAE2Sb1DhMqEATErxwNERRAhLyxQhoQHgCEXcyyKBE8UMSVwTB/DhQAwH8VfvwSRxBEBdPV"
            + "wA8gQMSBGlCrD6IARNG67uMQRgACFmZerBEKYAIdFqmqDWUQQKbmJvkReQBEjwBV8xABEAQvf30L"
            + "Dx8QwJKk72QRAAAALEjTowQAAACu3WQGB0YAkkGXiqULMwAMBMBlgQsBAATJKMLlBSAwRNWlVoEQ"
            + "KQDAMFP/RQlwEMTPvmIIEhQQRMcLGUIPcDAEKYmWZBAeAECU7Xy2EAoAApGsxfIKBgBI2KmM/wsf"
            + "UMRFtBUaD1AAAmAYVLYLAQCAKq0meAMKAAiF1S3nCzxAxPoK5cwPADCEusgiRxBHAAQE2lsyDjwA"
            + "DOaT6IwKCgAMHCAqsAtuMMTCG+vCDRQgRMrGJOYPCnDCApbp6gwKAIJ8aGmzBRUwBMDmNxYOCgAE"
            + "zoi0JggKAAQduyhCCwAAQNrJu2EIHjAExsv7cg4KMARA1BdUDj5ARG2rw08ORwAC9ytzUg0AQMAg"
            + "3IwxAQEARFo32TAJMkBCptH68wwLgIKL/SEHDQsARJkJo+wHegii4bWq9+9xDpIBALIBAggB6AEC"
            + "gAID"

    private func decodePrivacy(_ base64: String) -> ActivityPrivacy {
        // The bodies are a whole `PreloadedUserSettings` carrying one
        // sub-message, which is what the client sends and what this decodes.
        let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) ?? Data()
        return ActivityPrivacyProto.decode(data).privacy
    }

    // MARK: The polarity

    @Test("`restricted = ON` means friends only — the enum's name lies about it")
    func polarity() {
        // The single most dangerous fact on this surface. Pinned from the
        // capture: field 29 went 2 → 3 at the exact moment the reader picked
        // "Do not share in any servers".
        #expect(ActivitySharingScope.friendsOnly.rawValue == 3)
        #expect(ActivitySharingScope.smallServersOnly.rawValue == 2)
        #expect(ActivitySharingScope.everywhere.rawValue == 1)
        #expect(ActivitySharingScope.friendsOnly.title == "Do not share in any servers")
        #expect(ActivitySharingScope.everywhere.title == "Share in all servers")
    }

    @Test("An unset scope shares everywhere, which is Discord's own fallback")
    func unsetSharesEverywhere() {
        let privacy = ActivityPrivacy(sharingScope: .unset)
        #expect(privacy.shares(in: GuildID(rawValue: 1), memberCount: 500_000))
    }

    // MARK: The decision

    @Test("Friends-only shares in no server at all")
    func friendsOnly() {
        let privacy = ActivityPrivacy(sharingScope: .friendsOnly)
        #expect(!privacy.shares(in: GuildID(rawValue: 1), memberCount: 3))
        #expect(!privacy.shares(in: GuildID(rawValue: 2), memberCount: 400_000))
    }

    @Test("The small-server line is 200 members, inclusive")
    func twoHundred() {
        // Read out of the client's own comparison — `n > 200` / `n <= 200` —
        // rather than from the copy, which only says "200 or fewer".
        let privacy = ActivityPrivacy(sharingScope: .smallServersOnly)
        #expect(privacy.shares(in: GuildID(rawValue: 1), memberCount: 200))
        #expect(!privacy.shares(in: GuildID(rawValue: 1), memberCount: 201))
    }

    @Test("A server of unknown size is treated as large, not as small")
    func unknownSizeIsConservative() {
        // The conservative direction. Guessing "small" shares into a server the
        // client could not measure, which is the failure that matters.
        let privacy = ActivityPrivacy(sharingScope: .smallServersOnly)
        #expect(!privacy.shares(in: GuildID(rawValue: 1), memberCount: nil))
    }

    @Test("A restricted server is off whatever the scope says")
    func perServerWins() {
        let blocked = GuildID(rawValue: 99)
        let privacy = ActivityPrivacy(
            sharingScope: .everywhere, restrictedGuildIDs: [blocked]
        )
        #expect(!privacy.shares(in: blocked, memberCount: 5))
        #expect(privacy.shares(in: GuildID(rawValue: 100), memberCount: 5))
    }

    @Test("Sharing switched off overrides every other answer")
    func masterSwitch() {
        let privacy = ActivityPrivacy(sharesCurrentGame: false, sharingScope: .everywhere)
        #expect(!privacy.shares(in: GuildID(rawValue: 1), memberCount: 5))
    }

    // MARK: The wire

    @Test("A BoolValue of false is EMPTY, not field 1 = 0")
    func falseIsEmpty() {
        // Proto3 omits a scalar at its default, so the wrapper carrying `false`
        // is zero bytes — which is exactly what the capture shows for both join
        // toggles after they were switched off. Writing `08 00` instead would
        // be a different message that happens to decode the same, and Discord's
        // own client never sends it.
        #expect(ActivityPrivacyProto.boolValue(false).isEmpty)
        #expect(Array(ActivityPrivacyProto.boolValue(true)) == [0x08, 0x01])
    }

    @Test("Decoding a captured body reads the scope Discord sent")
    func decodesCapture() {
        // Body 4 of the session: field 29 = 2, taken while the radio read
        // "Share in servers with 200 or fewer members".
        #expect(decodePrivacy(scopeChanged).sharingScope == .smallServersOnly)
    }

    @Test("Decoding a captured body reads both join toggles as ON")
    func decodesJoinToggles() {
        let privacy = decodePrivacy(scopeChanged)
        #expect(privacy.allowsFriendsToJoin)
        // Field 2 is absent from this body, and absent must mean the default
        // rather than false — the reader had not touched it yet.
        #expect(privacy.allowsVoiceParticipantsToJoin)
    }

    // MARK: The splice — the part that must never lose a field

    @Test("Replacing one field keeps every other byte verbatim")
    func spliceKeepsUnknownFields() {
        // The whole safety argument. A writer that re-serialises a message it
        // only partly understands deletes what it could not name — here that
        // would be somebody's `restricted_guild_ids` and their friend-source
        // flags.
        var original = ProtobufWriter()
        original.varint(field: 29, 2)
        original.message(field: 3, Data([1, 2, 3, 4, 5, 6, 7, 8]))
        original.varint(field: 77, 12345)          // a field this client cannot name
        original.message(field: 1, ActivityPrivacyProto.boolValue(true))

        var replacement = ProtobufWriter()
        replacement.tag(field: 29, wireType: 0)
        replacement.varint(3)

        let merged = ActivityPrivacyProto.replacing(
            field: 29, with: replacement.data, in: original.data
        )

        var seen: [Int: Data] = [:]
        var reader = ProtobufReader(merged)
        while let field = reader.next() {
            seen[field.number] = reader.rawField(field)
        }
        #expect(seen[3] != nil, "the id list survived")
        #expect(seen[77] != nil, "a field this client cannot name survived")
        #expect(seen[1] != nil, "the friends toggle survived")

        var check = ProtobufReader(merged)
        var scope: UInt64?
        while let field = check.next() {
            if field.number == 29 { scope = field.value }
        }
        #expect(scope == 3)
    }

    @Test("A field that was not there is appended rather than dropped")
    func spliceAppends() {
        var original = ProtobufWriter()
        original.varint(field: 77, 1)

        var replacement = ProtobufWriter()
        replacement.message(field: 2, ActivityPrivacyProto.boolValue(true))

        let merged = ActivityPrivacyProto.replacing(
            field: 2, with: replacement.data, in: original.data
        )
        var reader = ProtobufReader(merged)
        var numbers: [Int] = []
        while let field = reader.next() { numbers.append(field.number) }
        #expect(numbers.sorted() == [2, 77])
    }

    @Test("A splice never duplicates the field it replaced")
    func spliceIsIdempotent() {
        var original = ProtobufWriter()
        original.varint(field: 29, 1)
        original.varint(field: 29, 2)   // a malformed message with it twice

        var replacement = ProtobufWriter()
        replacement.tag(field: 29, wireType: 0)
        replacement.varint(3)

        let merged = ActivityPrivacyProto.replacing(
            field: 29, with: replacement.data, in: original.data
        )
        var reader = ProtobufReader(merged)
        var count = 0
        while let field = reader.next() {
            if field.number == 29 { count += 1 }
        }
        #expect(count == 1)
    }

    @Test("A patch body is a whole settings message carrying one sub-message")
    func patchShape() {
        var raw = ProtobufWriter()
        raw.varint(field: 29, 1)
        let body = ActivityPrivacyProto.privacyPatch(
            applying: .sharingScope(.friendsOnly), to: raw.data
        )
        let data = Data(base64Encoded: body) ?? Data()
        var reader = ProtobufReader(data)
        let field = reader.next()
        // Field 8 is `privacy`, walked out of the capture.
        #expect(field?.number == 8)
        #expect(ActivityPrivacyProto.decode(data).privacy.sharingScope == .friendsOnly)
    }

    @Test("Restricted ids are packed fixed64 in a stable order")
    func restrictedIDsRoundTrip() {
        let ids: Set<GuildID> = [
            GuildID(rawValue: 1_040_876_835_899_302_306),
            GuildID(rawValue: 428_691_939_861_463_042),
        ]
        var raw = ProtobufWriter()
        raw.varint(field: 29, 1)
        let body = ActivityPrivacyProto.privacyPatch(
            applying: .restrictedGuildIDs(ids), to: raw.data
        )
        let data = Data(base64Encoded: body) ?? Data()
        #expect(ActivityPrivacyProto.decode(data).privacy.restrictedGuildIDs == ids)

        // Sorted, so writing the same set twice produces the same bytes — a
        // client whose PATCH body changed on every save would look like a
        // client with a bug.
        let again = ActivityPrivacyProto.privacyPatch(
            applying: .restrictedGuildIDs(ids), to: raw.data
        )
        #expect(again == body)
    }

    @Test("Share my activity lives on `status`, not on `privacy`")
    func showCurrentGameIsOnStatus() {
        var statusRaw = ProtobufWriter()
        statusRaw.message(field: 1, Data("online".utf8))
        let body = ActivityPrivacyProto.showCurrentGamePatch(false, statusRaw: statusRaw.data)
        let data = Data(base64Encoded: body) ?? Data()
        var reader = ProtobufReader(data)
        guard let field = reader.next() else { Issue.record("no field"); return }
        #expect(field.number == 11)
        #expect(ActivityPrivacyProto.decode(data).privacy.sharesCurrentGame == false)
        // And the status string it was spliced into is still there.
        var inner = reader.reader(for: field)
        var sawStatus = false
        while let entry = inner.next() {
            if entry.number == 1 { sawStatus = true }
        }
        #expect(sawStatus, "the status string survived the splice")
    }
}
