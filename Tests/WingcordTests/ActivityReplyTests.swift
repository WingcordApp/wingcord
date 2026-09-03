import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// The frames this client sends an activity.
///
/// **These fail silently and destructively, which is why they are pinned.** The
/// Embedded App SDK validates every inbound frame before it looks at the
/// contents; a frame that will not parse is logged with `console.error` and
/// dropped — and the SDK *overrides `console.error` to send `CAPTURE_LOG` back
/// to the client*. One malformed reply produces two log commands, whose two
/// malformed replies produce four. The frame's main thread saturates and the
/// activity appears to freeze mid-spinner. That is exactly what Watch Together
/// did, and none of it reaches a Swift error path.
///
/// Every expectation below is read off `@discord/embedded-app-sdk` 2.5.0's own
/// schemas, quoted where it is surprising.
@Suite("Activity replies")
struct ActivityReplyTests {

    /// Decoded rather than inspected as a dictionary: the *names* are what is
    /// under test, and a mirror that misspells one fails to decode.
    private struct Frame: Decodable {
        var cmd: String
        var evt: String?
        var nonce: String?
        /// Present-but-null and absent are different things here, and the whole
        /// bug was the difference. `Decodable` cannot tell them apart, so the
        /// raw object is checked separately in `keysPresent`.
        var data: [String: AnyDecodable]?
    }

    private struct AnyDecodable: Decodable {
        init(from decoder: any Decoder) throws {}
    }

    private func decode(_ body: [String: Any]?) throws -> Frame {
        let body = try #require(body)
        let data = try JSONSerialization.data(withJSONObject: body)
        return try JSONDecoder().decode(Frame.self, from: data)
    }

    /// Which keys are physically present, null or not.
    private func keysPresent(_ body: [String: Any]?) throws -> Set<String> {
        let body = try #require(body)
        return Set(body.keys)
    }

    // MARK: A command reply

    /// ```js
    /// const ReceiveFramePayload = objectType({
    ///     cmd: stringType(), data: unknownType(),
    ///     evt: nullType(),        // required, and must BE null
    ///     nonce: stringType(),    // required, and NOT nullable
    /// }).passthrough();
    /// ```
    @Test("A command reply carries evt explicitly, and it is null")
    func responseCarriesNullEvt() throws {
        let body = ActivityReply.response(command: "AUTHORIZE", nonce: "n1", data: ["code": "abc"])
        let keys = try keysPresent(body)
        // Present…
        #expect(keys.contains("evt"))
        // …and null. Omitting it is what broke this: the SDK's schema requires
        // the key, so an absent one fails the parse before `cmd` is read.
        #expect(body?["evt"] is NSNull)

        let frame = try decode(body)
        #expect(frame.cmd == "AUTHORIZE")
        #expect(frame.evt == nil)
        #expect(frame.nonce == "n1")
    }

    /// The whole frame is dropped rather than sent with a null nonce: nothing
    /// is waiting on one, and `ReceiveFramePayload.nonce` is not nullable.
    @Test("A reply with no nonce is not sent at all")
    func responseWithoutNonceIsDropped() {
        #expect(ActivityReply.response(command: "AUTHORIZE", nonce: nil, data: [:]) == nil)
        #expect(ActivityReply.response(command: nil, nonce: "n1", data: [:]) == nil)
        #expect(ActivityReply.error(
            command: "AUTHORIZE", nonce: nil, code: .invalidCommand, message: "x"
        ) == nil)
    }

    @Test("An error frame names the command and carries the code")
    func errorFrame() throws {
        let body = ActivityReply.error(
            command: "GET_GUILD", nonce: "n2", code: .invalidCommand, message: "nope"
        )
        let frame = try decode(body)
        #expect(frame.cmd == "GET_GUILD")
        #expect(frame.evt == "ERROR")
        #expect(frame.nonce == "n2")

        let data = try #require(body?["data"] as? [String: Any])
        #expect(data["code"] as? Int == 4002)
        #expect(data["message"] as? String == "nope")
    }

    // MARK: An event

    /// `DispatchEventFrame` widens the nonce where `ReceiveFramePayload` does
    /// not — an event answers nothing, so it has no nonce to carry.
    @Test("A dispatch is the one frame whose nonce may be null")
    func dispatchNonceIsNull() throws {
        let body = ActivityReply.dispatch(event: "READY", data: ["v": 1])
        #expect(try keysPresent(body).contains("nonce"))
        #expect(body["nonce"] is NSNull)

        let frame = try decode(body)
        #expect(frame.cmd == "DISPATCH")
        #expect(frame.evt == "READY")
        #expect(frame.nonce == nil)
    }

    // MARK: A user

    /// zod's `.optional()` accepts `undefined` and **rejects `null`**, so an
    /// account with no avatar must omit the key rather than send a null one.
    @Test("A nil avatar is omitted, never sent as null")
    func nilFieldsAreOmitted() throws {
        let bare = ActivityReply.user(
            id: "1", username: "alex", discriminator: "0",
            publicFlags: 256, avatar: nil, globalName: nil
        )
        #expect(Set(bare.keys) == ["id", "username", "discriminator", "public_flags"])

        let full = ActivityReply.user(
            id: "1", username: "alex", discriminator: "0",
            publicFlags: 256, avatar: "abc", globalName: "alex"
        )
        #expect(full["avatar"] as? String == "abc")
        #expect(full["global_name"] as? String == "alex")
    }

    /// Required outright by `AuthenticateResponseSchema`, and a number.
    @Test("public_flags is always present, as a number")
    func publicFlagsAlwaysPresent() throws {
        let user = ActivityReply.user(
            id: "1", username: "alex", discriminator: "0",
            publicFlags: 0, avatar: nil, globalName: nil
        )
        #expect(user["public_flags"] as? UInt64 == 0)
    }

    /// Everything this builder produces has to survive `JSONSerialization`.
    /// An `Optional` bridged through `Any` does not, and would drop the frame
    /// on the floor at the last moment — which is how the nonce field failed
    /// before it was made explicit.
    @Test("Every frame is a valid JSON object")
    func framesAreSerialisable() throws {
        let user = ActivityReply.user(
            id: "1", username: "alex", discriminator: "0",
            publicFlags: 256, avatar: nil, globalName: nil
        )
        let frames: [[String: Any]] = [
            try #require(ActivityReply.response(command: "AUTHORIZE", nonce: "n", data: user)),
            try #require(ActivityReply.error(
                command: "GET_GUILD", nonce: "n", code: .invalidPermissions, message: "no"
            )),
            ActivityReply.dispatch(event: "READY", data: ["v": 1, "user": user]),
        ]
        for frame in frames {
            #expect(JSONSerialization.isValidJSONObject(frame))
        }
    }
}
