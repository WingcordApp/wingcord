import Foundation
import Testing
@testable import WingcordCore
@testable import WingcordNet

/// Friend request notes on the wire: Discord's `sendRequest` (`49229`) and the
/// `note` on a relationship (`994500`).
@Suite("Friend request notes on the wire")
struct FriendRequestNoteWireTests {

    @Test("A note goes in the request's body")
    func sendsTheNote() async throws {
        let (rest, token) = await RequestRecorder.client()
        try await rest.sendFriendRequest(username: "wumpus", note: "let's be friends")
        let request = try #require(RequestRecorder.requests(for: token).first)
        #expect(request.method == "POST")
        #expect(request.path == "/api/v9/users/@me/relationships")
        #expect(request.json?["username"] as? String == "wumpus")
        #expect(request.json?["note"] as? String == "let's be friends")
        // Null, not absent: the shape Discord's own client sends.
        #expect(request.json?["discriminator"] is NSNull)
    }

    /// Discord's `undefined`, which `JSON.stringify` leaves out.
    @Test("No note is no key at all")
    func noNoteNoKey() async throws {
        let (rest, token) = await RequestRecorder.client()
        try await rest.sendFriendRequest(username: "wumpus")
        let request = try #require(RequestRecorder.requests(for: token).first)
        #expect(request.json?.keys.contains("note") == false)
    }

    @Test("A friend link asks the invites route and answers its code")
    func friendLink() async throws {
        let (rest, token) = await RequestRecorder.client(body: #"{"code":"abc123"}"#)
        let code = try await rest.createFriendInvite()
        #expect(code == "abc123")
        let request = try #require(RequestRecorder.requests(for: token).first)
        #expect(request.method == "POST")
        #expect(request.path == "/api/v9/users/@me/invites")
    }

    @Test("A relationship's note is read, and an empty one isn't a note")
    func decodesTheNote() throws {
        func dto(_ json: String) throws -> RelationshipDTO {
            try DiscordREST.decoder.decode(RelationshipDTO.self, from: Data(json.utf8))
        }
        let withNote = try dto(#"{"id":"1","type":3,"note":"hey there"}"#)
        #expect(withNote.facts?.note == "hey there")
        // On a relationship with nothing else remarkable, it's still worth a row.
        #expect(withNote.facts?.isNoteworthy == true)
        #expect(try dto(#"{"id":"1","type":3,"note":""}"#).facts == nil)
        #expect(try dto(#"{"id":"1","type":3}"#).facts == nil)
    }

    /// **Unset isn't "on"**: Discord's fallback hangs on telling the two apart.
    @Test("The setting says whether it was ever set")
    func settingPresence() {
        #expect(MessagingPrivacyProto.decode(Data()).privacy.hasFriendRequestNotesSetting == false)
        let raw = Data(base64Encoded: MessagingPrivacyProto.patch(applying: .friendRequestNotes(true), to: Data())) ?? Data()
        let decoded = MessagingPrivacyProto.decode(raw).privacy
        #expect(decoded.hasFriendRequestNotesSetting)
        #expect(decoded.showsFriendRequestNotes)
    }

    @Test("The account's own object says if it's cleared for age-restricted content")
    func nsfwAllowed() throws {
        let dto = try DiscordREST.decoder.decode(
            UserDTO.self,
            from: Data(#"{"id":"1","username":"a","nsfw_allowed":false}"#.utf8)
        )
        #expect(dto.currentAccount.isNSFWAllowed == false)
        let silent = try DiscordREST.decoder.decode(UserDTO.self, from: Data(#"{"id":"1","username":"a"}"#.utf8))
        #expect(silent.currentAccount.isNSFWAllowed == nil)
    }
}

/// `connected_at` only draws a clock, so it mustn't be able to fail a voice state.
@Suite("Voice state's joined time")
struct VoiceConnectedAtTests {
    private func state(_ field: String) throws -> VoiceState? {
        try DiscordREST.decoder.decode(
            VoiceStateDTO.self,
            from: Data(#"{"user_id":"1","channel_id":"2"\#(field)}"#.utf8)
        ).domain
    }

    @Test("Seconds since the epoch, as a number or a string")
    func readsIt() throws {
        #expect(try state(#","connected_at":1700000000"#)?.connectedAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(try state(#","connected_at":"1700000000""#)?.connectedAt == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test("Anything else is no clock, and the state survives")
    func survives() throws {
        #expect(try state("")?.channelID != nil)
        #expect(try state("")?.connectedAt == nil)
        #expect(try state(#","connected_at":null"#)?.connectedAt == nil)
        #expect(try state(#","connected_at":{"a":1}"#)?.connectedAt == nil)
        #expect(try state(#","connected_at":{"a":1}"#)?.channelID != nil)
    }
}
