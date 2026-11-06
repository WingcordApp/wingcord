import CryptoKit
import Foundation
import Testing
@testable import WingcordNet

/// The QR handshake, with the test playing Discord's gateway: it encrypts to
/// the public key the client introduced, exactly as `remote-auth-gateway`
/// would, and checks what comes back.
@Suite("QR code login handshake")
struct RemoteAuthHandshakeTests {

    private let key = try! RemoteAuthKey.generate()

    @Test("The public key goes out as SubjectPublicKeyInfo, as WebCrypto exports it")
    func spki() throws {
        // A 2048-bit key with exponent 65537 is 294 bytes of SPKI, and always
        // opens with the same nineteen.
        #expect(key.spki.count == 294)
        let prefix: [UInt8] = [
            0x30, 0x82, 0x01, 0x22, 0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D,
            0x01, 0x01, 0x01, 0x05, 0x00, 0x03, 0x82, 0x01, 0x0F, 0x00,
        ]
        #expect(Array(key.spki.prefix(prefix.count)) == prefix)
    }

    @Test("DER lengths: short form under 128, long form after")
    func derLength() {
        #expect(RemoteAuthKey.derLength(0x7F) == [0x7F])
        #expect(RemoteAuthKey.derLength(0x80) == [0x81, 0x80])
        #expect(RemoteAuthKey.derLength(0x122) == [0x82, 0x01, 0x22])
    }

    @Test("The fingerprint is base64url(SHA-256(SPKI)), unpadded")
    func fingerprint() {
        let expected = Data(SHA256.hash(data: key.spki)).base64EncodedString()
            .replacing("/", with: "_").replacing("+", with: "-").replacing("=", with: "")
        #expect(key.fingerprint == expected)
        #expect(key.fingerprint.count == 43)
        #expect(!key.fingerprint.contains(where: { "+/=".contains($0) }))
    }

    @Test("Opening introduces the key")
    func opened() throws {
        let outputs = RemoteAuthHandshake(key: key).opened()
        guard case .send(let text) = try #require(outputs.first) else {
            Issue.record("expected a frame")
            return
        }
        let frame = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String])
        #expect(frame["op"] == "init")
        #expect(frame["encoded_public_key"] == key.spki.base64EncodedString())
    }

    @Test("Hello starts the heartbeat at Discord's interval")
    func hello() throws {
        let outputs = try RemoteAuthHandshake(key: key).receive(
            #"{"op":"hello","heartbeat_interval":41250,"timeout_ms":120000}"#
        )
        #expect(outputs == [.startHeartbeat(interval: .milliseconds(41_250))])
    }

    @Test("The nonce comes back decrypted, as base64url")
    func nonceProof() throws {
        let nonce = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let encrypted = try key.encryptForTesting(nonce)
        let outputs = try RemoteAuthHandshake(key: key).receive(
            #"{"op":"nonce_proof","encrypted_nonce":"\#(encrypted)"}"#
        )
        guard case .send(let text) = try #require(outputs.first) else {
            Issue.record("expected a frame")
            return
        }
        let frame = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String])
        #expect(frame["op"] == "nonce_proof")
        #expect(frame["nonce"] == RemoteAuthCrypto.base64URL(nonce))
    }

    @Test("A matching fingerprint makes the code; another key's is refused")
    func remoteInit() throws {
        let handshake = RemoteAuthHandshake(key: key)
        let outputs = try handshake.receive(#"{"op":"pending_remote_init","fingerprint":"\#(key.fingerprint)"}"#)
        #expect(outputs == [.ready(
            url: URL(string: "https://discord.com/ra/\(key.fingerprint)")!,
            fingerprint: key.fingerprint
        )])
        #expect(throws: RemoteAuthError.fingerprintMismatch) {
            _ = try handshake.receive(#"{"op":"pending_remote_init","fingerprint":"somebody-else"}"#)
        }
    }

    @Test("A scan names who's on the phone")
    func scanned() throws {
        let payload = try key.encryptForTesting(Data("80351110225439422:0:a_1f2e3d:alex".utf8))
        let outputs = try RemoteAuthHandshake(key: key).receive(
            #"{"op":"pending_ticket","encrypted_user_payload":"\#(payload)"}"#
        )
        #expect(outputs == [.scanned(RemoteAuthUser(
            id: "80351110225439422", discriminator: "0", avatarHash: "a_1f2e3d", username: "alex"
        ))])
    }

    @Test("A user payload: no avatar is 0, a username may hold colons, garbage is refused")
    func userPayload() {
        #expect(RemoteAuthHandshake.user(from: "1:0:0:name")?.avatarHash == nil)
        #expect(RemoteAuthHandshake.user(from: "1:1234:abc:a:b:c")?.username == "a:b:c")
        #expect(RemoteAuthHandshake.user(from: "x:0:0:name") == nil)
        #expect(RemoteAuthHandshake.user(from: "1:12345:0:name") == nil)
        #expect(RemoteAuthHandshake.user(from: "1:0:a-b:name") == nil)
        #expect(RemoteAuthHandshake.user(from: "1:0:0") == nil)
    }

    @Test("Approval hands over the ticket; the token decrypts with the same key")
    func login() throws {
        let handshake = RemoteAuthHandshake(key: key)
        #expect(try handshake.receive(#"{"op":"pending_login","ticket":"TICKET"}"#) == [.ticket("TICKET")])
        let encrypted = try key.encryptForTesting(Data("the-token".utf8))
        #expect(try handshake.decryptToken(encrypted) == "the-token")
    }

    @Test("Cancel starts over; an unknown op is ignored; a broken frame throws")
    func other() throws {
        let handshake = RemoteAuthHandshake(key: key)
        #expect(try handshake.receive(#"{"op":"cancel"}"#) == [.cancelled])
        #expect(try handshake.receive(#"{"op":"heartbeat_ack"}"#) == [.heartbeatAcknowledged])
        #expect(try handshake.receive(#"{"op":"something_new"}"#).isEmpty)
        #expect(throws: RemoteAuthError.self) { _ = try handshake.receive("not json") }
    }

    @Test("A token encrypted to another key doesn't decrypt")
    func wrongKey() throws {
        let other = try RemoteAuthKey.generate()
        let encrypted = try other.encryptForTesting(Data("the-token".utf8))
        #expect(throws: RemoteAuthError.self) {
            _ = try RemoteAuthHandshake(key: key).decryptToken(encrypted)
        }
    }

    @Test("The heartbeat frame is Discord's")
    func heartbeatFrame() {
        #expect(RemoteAuthHandshake.heartbeatFrame == #"{"op":"heartbeat"}"#)
    }
}
