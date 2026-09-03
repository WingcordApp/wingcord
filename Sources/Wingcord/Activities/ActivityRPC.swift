import Foundation
import WingcordCore

// MARK: - The Embedded App SDK's wire protocol
//
// An activity talks to its host over `window.postMessage`, not over HTTP — so
// none of this is in a HAR and none of it could be. **It is read off the
// shipping SDK instead**: `@discord/embedded-app-sdk` 2.5.0, MIT, from npm.
// The opcodes below are its `Opcodes` enum verbatim, the envelope is its
// `parseIncomingPayload`, and the handshake is its `handshake()`. Where
// `docs.discord.food` describes the same commands it agrees, but the source is
// what these were written from.
//
// ```js
// // Discord.mjs
// Opcodes[Opcodes["HANDSHAKE"] = 0]
// Opcodes[Opcodes["FRAME"]     = 1]
// Opcodes[Opcodes["CLOSE"]     = 2]
// Opcodes[Opcodes["HELLO"]     = 3]
//
// source.postMessage([Opcodes.HANDSHAKE,
//   { v: 1, encoding: 'json', client_id, frame_id, sdk_version }], origin)
// source.postMessage([Opcodes.FRAME, { ...payload, nonce }], origin, transfer)
// ```

enum ActivityOpcode: Int, Sendable {
    case handshake = 0
    case frame = 1
    case close = 2
    case hello = 3
}

/// One message from the frame.
///
/// The envelope is `{cmd, args, nonce, evt}` outbound and `{cmd, data, nonce,
/// evt}` inbound. `DISPATCH` is a `cmd` like any other on the wire but is
/// deliberately outside the SDK's own `Commands` enum — it is how an *event*
/// reaches the app rather than a reply to anything it asked for.
struct ActivityFrameMessage: Sendable {
    var opcode: ActivityOpcode
    var command: String?
    var event: String?
    var nonce: String?
    var arguments: [String: Any]
    /// The payload object as it arrived.
    ///
    /// **A `CLOSE` carries `{code, message}` at the top level, not under
    /// `args`** — the SDK sends `[2, {code, message, nonce}]` — so a reader
    /// that only looks at `args` learns nothing about why an activity gave up.
    /// Kept whole rather than adding two fields that mean something on exactly
    /// one opcode.
    var body: [String: Any]

    /// Nothing here is `Codable`: the payloads are open-ended JSON an app
    /// composes, and modelling every command's arguments as a Swift type would
    /// be inventing shapes for commands this client refuses anyway.
    init?(json: Any) {
        guard let pair = json as? [Any], pair.count >= 1,
              let raw = pair[0] as? Int,
              let opcode = ActivityOpcode(rawValue: raw)
        else { return nil }
        self.opcode = opcode
        let body = pair.count > 1 ? (pair[1] as? [String: Any] ?? [:]) : [:]
        command = body["cmd"] as? String
        event = body["evt"] as? String
        nonce = body["nonce"] as? String
        arguments = body["args"] as? [String: Any] ?? [:]
        self.body = body
    }

    /// Why the frame closed itself, when it did.
    ///
    /// The codes are the SDK's `RPCCloseCodes`: `1000` normal, `1003`
    /// unsupported, `1006` abnormal, `4000` invalid client id, `4001` invalid
    /// origin, `4002` rate limited, `4003` token revoked, `4004` invalid
    /// version, `4005` invalid encoding.
    var closeReason: (code: Int, message: String?) {
        (body["code"] as? Int ?? -1, body["message"] as? String)
    }
}

/// The RPC error codes the SDK knows, for the replies this client refuses.
///
/// Only the two that are actually reachable here are named. An app that asks
/// for something unimplemented gets `INVALID_COMMAND` — **an error, never
/// silence.** A command left unanswered is an app that hangs on a promise
/// forever, which looks like a broken activity rather than a missing feature.
enum ActivityRPCError: Int, Sendable {
    case invalidCommand = 4002
    case invalidPermissions = 4006
}


// MARK: - Building a reply

/// The three frame shapes this client sends, and the only place their spelling
/// lives.
///
/// **Pure, and separate from the bridge, because getting one wrong is not a
/// visible failure.** A frame the SDK cannot parse is logged with
/// `console.error` and dropped — and the SDK overrides `console.error` to send
/// `CAPTURE_LOG` *back*, so a malformed reply produces two log commands whose
/// malformed replies produce four. The frame's main thread saturates and the
/// activity appears to freeze. `ActivityReplyTests` pins every required field.
nonisolated enum ActivityReply {

    /// A reply to a command.
    ///
    /// ```js
    /// const ReceiveFramePayload = objectType({
    ///     cmd: stringType(), data: unknownType(),
    ///     evt: nullType(),        // required, and must BE null
    ///     nonce: stringType(),    // required, and NOT nullable
    /// }).passthrough();
    /// ```
    ///
    /// Nil when there is no nonce to answer: nothing is waiting on such a
    /// frame, and an `ERROR` needs one too.
    static func response(
        command: String?,
        nonce: String?,
        data: [String: Any]
    ) -> [String: Any]? {
        guard let command, let nonce else { return nil }
        return ["cmd": command, "data": data, "evt": NSNull(), "nonce": nonce]
    }

    static func error(
        command: String?,
        nonce: String?,
        code: ActivityRPCError,
        message: String
    ) -> [String: Any]? {
        guard let command, let nonce else { return nil }
        return [
            "cmd": command,
            "evt": "ERROR",
            "data": ["code": code.rawValue, "message": message],
            "nonce": nonce,
        ]
    }

    /// An event. The one frame shape whose nonce may be null —
    /// `DispatchEventFrame` widens it where `ReceiveFramePayload` does not.
    static func dispatch(event: String, data: [String: Any]) -> [String: Any] {
        ["cmd": "DISPATCH", "evt": event, "data": data, "nonce": NSNull()]
    }

    /// A user, as every schema that carries one spells it.
    ///
    /// **A nil field is OMITTED, never sent as null.** `avatar` and
    /// `global_name` are `.optional()`, and zod's `.optional()` accepts
    /// `undefined` — it does **not** accept `null`. `public_flags` is required
    /// outright by `AuthenticateResponseSchema`.
    static func user(
        id: String,
        username: String,
        discriminator: String,
        publicFlags: UInt64,
        avatar: String?,
        globalName: String?
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "id": id,
            "username": username,
            "discriminator": discriminator,
            "public_flags": publicFlags,
        ]
        if let avatar { payload["avatar"] = avatar }
        if let globalName { payload["global_name"] = globalName }
        return payload
    }
}
