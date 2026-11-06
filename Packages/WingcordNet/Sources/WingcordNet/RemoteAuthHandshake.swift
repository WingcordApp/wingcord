import CryptoKit
import Foundation
import Security

// Logging in with a QR code: the handshake Discord's mobile app completes.
//
// **Read out of the web bundle, build 663810** (`6830a1b682683d22.js`, module
// `52423`), version 2 of the protocol, and never run against Discord before
// this was written:
//
//     → init          {encoded_public_key: base64(SPKI)}
//     ← hello         {heartbeat_interval, timeout_ms}
//     ← nonce_proof   {encrypted_nonce}       → nonce_proof {nonce: base64url(plain)}
//     ← pending_remote_init {fingerprint}     the code: discord.com/ra/{fingerprint}
//     ← pending_ticket {encrypted_user_payload}   "id:discriminator:avatar:username"
//     ← pending_login {ticket}                POST /users/@me/remote-auth/login
//     ← cancel                                 the phone said no: start over
//
// Everything encrypted is RSA-OAEP with SHA-256, to a 2048-bit key this side
// makes for the one handshake and never keeps. The fingerprint is
// base64url(SHA-256(SPKI)) without padding, and **it is checked**: a gateway
// that names another key is not the one this key's code was meant for.
//
// This type is the protocol and nothing else — no socket, no clock — so every
// step can be driven by a test playing the gateway with the public key.
// `RemoteAuthSession` is the socket around it.

/// The handshake's own key pair.
public struct RemoteAuthKey: @unchecked Sendable {
    // `SecKey` is a CF type the compiler can't see is immutable; it is, and
    // both keys are only ever read.
    let privateKey: SecKey
    let publicKey: SecKey
    /// The public key as SubjectPublicKeyInfo DER: what WebCrypto's
    /// `exportKey("spki")` gives the web client.
    public let spki: Data

    /// A fresh 2048-bit RSA key, as the web client's `generateRsaKeyPair`.
    public static func generate() throws -> RemoteAuthKey {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error),
              let publicKey = SecKeyCopyPublicKey(privateKey),
              let pkcs1 = SecKeyCopyExternalRepresentation(publicKey, &error) as Data?
        else {
            throw RemoteAuthError.crypto(error?.takeRetainedValue().localizedDescription ?? "no key")
        }
        return RemoteAuthKey(privateKey: privateKey, publicKey: publicKey, spki: Self.spki(wrapping: pkcs1))
    }

    /// `init`'s field: the SPKI, base64 as `btoa` writes it.
    public var encodedPublicKey: String { spki.base64EncodedString() }

    /// base64url(SHA-256(SPKI)), unpadded: the code's last path component.
    public var fingerprint: String {
        RemoteAuthCrypto.base64URL(Data(SHA256.hash(data: spki)))
    }

    /// RSA-OAEP with SHA-256 — the same digest for the mask, as WebCrypto's
    /// `{name:"RSA-OAEP", hash:"SHA-256"}` uses.
    public func decrypt(_ base64: String) throws -> Data {
        guard let cipher = Data(base64Encoded: base64) else {
            throw RemoteAuthError.malformed("not base64")
        }
        var error: Unmanaged<CFError>?
        guard let plain = SecKeyCreateDecryptedData(
            privateKey, .rsaEncryptionOAEPSHA256, cipher as CFData, &error
        ) as Data? else {
            throw RemoteAuthError.crypto(error?.takeRetainedValue().localizedDescription ?? "decrypt failed")
        }
        return plain
    }

    /// For a test playing the gateway: what Discord's side would send.
    public func encryptForTesting(_ plain: Data) throws -> String {
        var error: Unmanaged<CFError>?
        guard let cipher = SecKeyCreateEncryptedData(
            publicKey, .rsaEncryptionOAEPSHA256, plain as CFData, &error
        ) as Data? else {
            throw RemoteAuthError.crypto(error?.takeRetainedValue().localizedDescription ?? "encrypt failed")
        }
        return cipher.base64EncodedString()
    }

    /// PKCS#1 `RSAPublicKey` wrapped as SubjectPublicKeyInfo.
    ///
    /// **Security hands back PKCS#1, and WebCrypto's `spki` is the wrapped
    /// form** — so the fingerprint is computed over the wrapper too, or the
    /// gateway's `pending_remote_init` never matches and every code is refused.
    static func spki(wrapping pkcs1: Data) -> Data {
        // SEQUENCE { OID 1.2.840.113549.1.1.1 rsaEncryption, NULL }
        let algorithm: [UInt8] = [
            0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00,
        ]
        var bitString: [UInt8] = [0x03]
        bitString += derLength(pkcs1.count + 1)
        bitString.append(0x00) // no unused bits
        bitString += pkcs1
        let content = algorithm + bitString
        return Data([0x30] + derLength(content.count) + content)
    }

    static func derLength(_ length: Int) -> [UInt8] {
        if length < 0x80 { return [UInt8(length)] }
        var bytes: [UInt8] = []
        var remaining = length
        while remaining > 0 {
            bytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }
}

public enum RemoteAuthError: Error, Sendable, Equatable {
    case crypto(String)
    case malformed(String)
    /// `pending_remote_init` named another key.
    case fingerprintMismatch
}

enum RemoteAuthCrypto {
    /// base64url without padding: the web client's `O`.
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacing("/", with: "_")
            .replacing("+", with: "-")
            .replacing("=", with: "")
    }
}

/// What the handshake asks of whoever runs it.
public enum RemoteAuthOutput: Sendable, Equatable {
    /// A text frame to send.
    case send(String)
    /// `hello` arrived: heartbeat every `interval`, the first after a random
    /// part of it, as the web client does.
    case startHeartbeat(interval: Duration)
    /// The code to show, at last.
    case ready(url: URL, fingerprint: String)
    /// Somebody scanned it and their phone is asking them.
    case scanned(RemoteAuthUser)
    /// They said yes: exchange this ticket for the token.
    case ticket(String)
    /// They said no on the phone. Start over with a new key.
    case cancelled
    /// The last heartbeat was answered.
    case heartbeatAcknowledged
}

/// The protocol, one frame at a time.
public struct RemoteAuthHandshake: Sendable {
    public let key: RemoteAuthKey

    public init(key: RemoteAuthKey) {
        self.key = key
    }

    /// Where the code points, for a fingerprint.
    public static func codeURL(fingerprint: String) -> URL {
        URL(string: "https://discord.com/ra/\(fingerprint)")!
    }

    /// The socket is open: introduce the key.
    public func opened() -> [RemoteAuthOutput] {
        [.send(Self.json(["op": "init", "encoded_public_key": key.encodedPublicKey]))]
    }

    /// The frame every heartbeat sends.
    public static let heartbeatFrame = json(["op": "heartbeat"])

    /// One frame from the gateway.
    public func receive(_ text: String) throws -> [RemoteAuthOutput] {
        guard let data = text.data(using: .utf8),
              let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let op = message["op"] as? String
        else { throw RemoteAuthError.malformed("not a frame") }

        switch op {
        case "hello":
            let milliseconds = (message["heartbeat_interval"] as? NSNumber)?.intValue ?? 41_250
            return [.startHeartbeat(interval: .milliseconds(max(1_000, milliseconds)))]
        case "heartbeat_ack":
            return [.heartbeatAcknowledged]
        case "nonce_proof":
            guard let encrypted = message["encrypted_nonce"] as? String else {
                throw RemoteAuthError.malformed("nonce_proof without a nonce")
            }
            let nonce = RemoteAuthCrypto.base64URL(try key.decrypt(encrypted))
            return [.send(Self.json(["op": "nonce_proof", "nonce": nonce]))]
        case "pending_remote_init":
            guard let fingerprint = message["fingerprint"] as? String else {
                throw RemoteAuthError.malformed("pending_remote_init without a fingerprint")
            }
            guard fingerprint == key.fingerprint else { throw RemoteAuthError.fingerprintMismatch }
            return [.ready(url: Self.codeURL(fingerprint: fingerprint), fingerprint: fingerprint)]
        case "pending_ticket":
            guard let encrypted = message["encrypted_user_payload"] as? String else {
                throw RemoteAuthError.malformed("pending_ticket without a payload")
            }
            let payload = String(decoding: try key.decrypt(encrypted), as: UTF8.self)
            guard let user = Self.user(from: payload) else {
                throw RemoteAuthError.malformed("unreadable user payload")
            }
            return [.scanned(user)]
        case "pending_login":
            guard let ticket = message["ticket"] as? String, !ticket.isEmpty else {
                throw RemoteAuthError.malformed("pending_login without a ticket")
            }
            return [.ticket(ticket)]
        case "cancel":
            return [.cancelled]
        default:
            // The web client logs and carries on; so does this.
            return []
        }
    }

    /// The token, out of `remote-auth/login`'s `encrypted_token`.
    public func decryptToken(_ encrypted: String) throws -> String {
        let token = String(decoding: try key.decrypt(encrypted), as: UTF8.self)
        guard !token.isEmpty else { throw RemoteAuthError.malformed("empty token") }
        return token
    }

    /// `id:discriminator:avatar:username`, as the web client's `D` reads it:
    /// `^(\d+):(\d{1,4}):([a-zA-Z0-9_]+):(.*)$`, an avatar of "0" meaning none.
    /// The username is everything after the third colon, colons included.
    static func user(from payload: String) -> RemoteAuthUser? {
        let parts = payload.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let id = String(parts[0]), discriminator = String(parts[1]), avatar = String(parts[2])
        guard !id.isEmpty, id.allSatisfy(\.isASCIIDigit),
              (1...4).contains(discriminator.count), discriminator.allSatisfy(\.isASCIIDigit),
              !avatar.isEmpty, avatar.allSatisfy({ $0.isASCIIAlphanumeric || $0 == "_" })
        else { return nil }
        return RemoteAuthUser(
            id: id,
            discriminator: discriminator,
            avatarHash: avatar == "0" ? nil : avatar,
            username: String(parts[3])
        )
    }

    static func json(_ object: [String: String]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
    var isASCIIAlphanumeric: Bool {
        isASCIIDigit || ("a"..."z").contains(self) || ("A"..."Z").contains(self)
    }
}
