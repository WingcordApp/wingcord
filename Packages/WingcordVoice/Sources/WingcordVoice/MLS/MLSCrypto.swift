import CryptoKit
import Foundation

// MARK: - One ciphersuite, and every primitive the platform already had
//
// DAVE pins MLS ciphersuite **2**, `MLS_128_DHKEMP256_AES128GCM_SHA256_P256`,
// and nothing here is generic over any other. That is deliberate: a ciphersuite
// abstraction would be five protocols and a dozen existentials to express a
// choice that Discord does not offer, and every one of them would be a place
// for the wrong hash to be threaded into the right slot.
//
//   KDF        HKDF-SHA256              Nh = 32
//   AEAD       AES-128-GCM              Nk = 16, Nn = 12
//   Hash       SHA-256
//   Signature  ECDSA P-256 / SHA-256, DER encoded
//   KEM        DHKEM(P-256, HKDF-SHA256), HPKE base mode (RFC 9180)
//
// **CryptoKit supplies all five.** The only thing it does not expose is HPKE's
// `DeriveKeyPair`, which MLS needs to turn a path secret into a node's key pair
// — so that one is written out below against RFC 9180 §7.1.3 rather than
// approximated, because "derive a P-256 key from a secret" has half a dozen
// plausible spellings and only one of them interoperates.
//
// Every construction in this file is prefixed with a label. That is not
// decoration: it is what stops a signature over one structure from verifying
// over a different structure that happens to serialise the same way.

enum MLSCrypto {
    // MARK: Sizes

    /// KDF.Nh — the length of an Extract output, and of every secret in the
    /// key schedule.
    static let hashLength = 32
    /// AEAD.Nk
    static let aeadKeyLength = 16
    /// AEAD.Nn
    static let aeadNonceLength = 12

    static let cipherSuiteID: UInt16 = 2
    static let protocolVersion: UInt16 = 1

    // MARK: Hash

    static func hash(_ bytes: [UInt8]) -> [UInt8] {
        Array(SHA256.hash(data: bytes))
    }

    static func hash(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
        Array(SHA256.hash(data: bytes))
    }

    // MARK: HKDF

    /// `KDF.Extract(salt, ikm)`.
    ///
    /// The argument order is the one the RFC's key-schedule diagram uses —
    /// salt from the top, IKM from the left — and it is the reverse of how
    /// HMAC's own arguments read, which is the classic way to get this wrong.
    static func extract(salt: [UInt8], ikm: [UInt8]) -> [UInt8] {
        Array(HKDF<SHA256>.extract(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: salt
        ))
    }

    static func expand(prk: [UInt8], info: [UInt8], length: Int) -> [UInt8] {
        HKDF<SHA256>.expand(
            pseudoRandomKey: prk,
            info: info,
            outputByteCount: length
        ).withUnsafeBytes { Array($0) }
    }

    /// `ExpandWithLabel(Secret, Label, Context, Length)` — RFC 9420 §8.
    ///
    /// The `KDFLabel` it expands over carries the output length, so two
    /// derivations that differ only in how many bytes they wanted are still
    /// different derivations.
    static func expandWithLabel(
        secret: [UInt8],
        label: String,
        context: [UInt8],
        length: Int
    ) -> [UInt8] {
        var writer = TLSWriter(reserving: 16 + label.utf8.count + context.count)
        writer.write(UInt16(length))
        // `try!`: the two vectors here are a label under 64 bytes and a context
        // the caller already holds in memory, so the only failure `writeOpaque`
        // has — a vector past 2^30 bytes — is unreachable.
        try! writer.writeOpaque(Array("MLS 1.0 \(label)".utf8))
        try! writer.writeOpaque(context)
        return expand(prk: secret, info: writer.bytes, length: length)
    }

    /// `DeriveSecret(Secret, Label)` — an `ExpandWithLabel` with no context and
    /// a full-hash output.
    static func deriveSecret(secret: [UInt8], label: String) -> [UInt8] {
        expandWithLabel(secret: secret, label: label, context: [], length: hashLength)
    }

    /// `DeriveTreeSecret(Secret, Label, Generation, Length)` — RFC 9420 §9.1.
    /// The generation is the context, as a big-endian `uint32`.
    static func deriveTreeSecret(
        secret: [UInt8],
        label: String,
        generation: UInt32,
        length: Int
    ) -> [UInt8] {
        var context = TLSWriter(reserving: 4)
        context.write(generation)
        return expandWithLabel(
            secret: secret, label: label, context: context.bytes, length: length
        )
    }

    // MARK: MAC

    /// `MAC(key, message)` — HMAC under the suite's hash. Used for the
    /// confirmation tag and the membership tag.
    static func mac(key: [UInt8], message: [UInt8]) -> [UInt8] {
        Array(HMAC<SHA256>.authenticationCode(
            for: message, using: SymmetricKey(data: key)
        ))
    }

    // MARK: Hash-based identifiers

    /// `RefHash(label, value)` — RFC 9420 §5.2.
    static func refHash(label: String, value: [UInt8]) throws -> [UInt8] {
        var writer = TLSWriter(reserving: label.utf8.count + value.count + 8)
        try writer.writeOpaque(Array(label.utf8))
        try writer.writeOpaque(value)
        return hash(writer.bytes)
    }

    static func keyPackageRef(_ marshalledKeyPackage: [UInt8]) throws -> [UInt8] {
        try refHash(label: "MLS 1.0 KeyPackage Reference", value: marshalledKeyPackage)
    }

    static func proposalRef(_ marshalledAuthenticatedContent: [UInt8]) throws -> [UInt8] {
        try refHash(label: "MLS 1.0 Proposal Reference", value: marshalledAuthenticatedContent)
    }

    // MARK: Signing

    /// `SignWithLabel(SignatureKey, Label, Content)` — RFC 9420 §5.1.2.
    ///
    /// The signature is DER, which is what RFC 8446 specifies for
    /// `ecdsa_secp256r1_sha256` and therefore what every other MLS stack emits.
    static func sign(
        privateKey: P256.Signing.PrivateKey,
        label: String,
        content: [UInt8]
    ) throws -> [UInt8] {
        let signature = try privateKey.signature(for: signContent(label: label, content: content))
        return Array(signature.derRepresentation)
    }

    static func verify(
        publicKey: [UInt8],
        label: String,
        content: [UInt8],
        signature: [UInt8]
    ) -> Bool {
        guard let key = try? P256.Signing.PublicKey(x963Representation: publicKey),
              let value = try? P256.Signing.ECDSASignature(derRepresentation: signature)
        else { return false }
        return key.isValidSignature(value, for: signContent(label: label, content: content))
    }

    private static func signContent(label: String, content: [UInt8]) -> [UInt8] {
        var writer = TLSWriter(reserving: label.utf8.count + content.count + 16)
        try! writer.writeOpaque(Array("MLS 1.0 \(label)".utf8))
        try! writer.writeOpaque(content)
        return writer.bytes
    }

    // MARK: HPKE

    static let hpkeSuite = HPKE.Ciphersuite(
        kem: .P256_HKDF_SHA256, kdf: .HKDF_SHA256, aead: .AES_GCM_128
    )

    struct HPKESealed {
        var kemOutput: [UInt8]
        var ciphertext: [UInt8]
    }

    /// `EncryptWithLabel(PublicKey, Label, Context, Plaintext)` — RFC 9420
    /// §5.1.3, which is HPKE `SealBase` with the label and context as `info`
    /// and an empty AAD.
    static func encrypt(
        to publicKey: [UInt8],
        label: String,
        context: [UInt8],
        plaintext: [UInt8]
    ) throws -> HPKESealed {
        let recipient = try P256.KeyAgreement.PublicKey(x963Representation: publicKey)
        var sender = try HPKE.Sender(
            recipientKey: recipient,
            ciphersuite: hpkeSuite,
            info: Data(encryptContext(label: label, context: context))
        )
        let ciphertext = try sender.seal(Data(plaintext), authenticating: Data())
        return HPKESealed(
            kemOutput: Array(sender.encapsulatedKey), ciphertext: Array(ciphertext)
        )
    }

    /// `DecryptWithLabel(PrivateKey, Label, Context, KEMOutput, Ciphertext)`.
    static func decrypt(
        with privateKey: P256.KeyAgreement.PrivateKey,
        label: String,
        context: [UInt8],
        sealed: HPKESealed
    ) throws -> [UInt8] {
        var recipient = try HPKE.Recipient(
            privateKey: privateKey,
            ciphersuite: hpkeSuite,
            info: Data(encryptContext(label: label, context: context)),
            encapsulatedKey: Data(sealed.kemOutput)
        )
        return Array(try recipient.open(Data(sealed.ciphertext), authenticating: Data()))
    }

    private static func encryptContext(label: String, context: [UInt8]) -> [UInt8] {
        var writer = TLSWriter(reserving: label.utf8.count + context.count + 16)
        try! writer.writeOpaque(Array("MLS 1.0 \(label)".utf8))
        try! writer.writeOpaque(context)
        return writer.bytes
    }

    // MARK: DeriveKeyPair

    /// HPKE's `DeriveKeyPair` for DHKEM(P-256, HKDF-SHA256) — RFC 9180 §7.1.3.
    ///
    /// **The one primitive CryptoKit does not expose, and the one MLS cannot do
    /// without**: every node on an update path gets its key pair from a path
    /// secret through exactly this function, so a client that improvises it
    /// derives a different tree from everybody else and every commit it makes
    /// is rejected.
    ///
    /// The rejection-sampling loop is not defensive coding. A uniform 32-byte
    /// string is a valid P-256 scalar with probability just under 1, and the
    /// specification's answer to the remainder is to expand again with the
    /// counter bumped — so a counter that only ever reaches 1 in practice is
    /// still part of the definition.
    static func deriveKeyPair(ikm: [UInt8]) throws -> P256.KeyAgreement.PrivateKey {
        // suite_id = "KEM" || I2OSP(kem_id, 2), kem_id = 0x0010 for P-256.
        let suiteID: [UInt8] = Array("KEM".utf8) + [0x00, 0x10]
        let version = Array("HPKE-v1".utf8)

        let dkpPRK = extract(
            salt: [],
            ikm: version + suiteID + Array("dkp_prk".utf8) + ikm
        )

        for counter in UInt8(0)...UInt8(255) {
            var info: [UInt8] = []
            info.reserveCapacity(2 + version.count + suiteID.count + 10)
            info.append(0)   // I2OSP(Nsk = 32, 2)
            info.append(32)
            info.append(contentsOf: version)
            info.append(contentsOf: suiteID)
            info.append(contentsOf: Array("candidate".utf8))
            info.append(counter)

            // The bitmask for P-256 is 0xff, so the candidate is used as it
            // comes; it is written out because the sibling curves mask here and
            // a reader should see that this one deliberately does not.
            let candidate = expand(prk: dkpPRK, info: info, length: 32)
            if let key = try? P256.KeyAgreement.PrivateKey(rawRepresentation: candidate) {
                return key
            }
        }
        throw MLSError.keyDerivationFailed
    }

    /// Signature key pairs are generated, never derived: MLS binds a member's
    /// identity to a key it chose, and DAVE's are ephemeral for the call.
    static func generateSignatureKey() -> P256.Signing.PrivateKey {
        P256.Signing.PrivateKey()
    }

    static func generateEncryptionKey() -> P256.KeyAgreement.PrivateKey {
        P256.KeyAgreement.PrivateKey()
    }

    static func publicKeyBytes(_ key: P256.KeyAgreement.PrivateKey) -> [UInt8] {
        Array(key.publicKey.x963Representation)
    }

    static func publicKeyBytes(_ key: P256.Signing.PrivateKey) -> [UInt8] {
        Array(key.publicKey.x963Representation)
    }

    static func random(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        return bytes
    }
}

// MARK: - Failures

enum MLSError: Error, CustomStringConvertible {
    case keyDerivationFailed
    case unsupportedCipherSuite(UInt16)
    case unsupportedVersion(UInt16)
    case unsupportedWireFormat(UInt16)
    case unsupportedProposal(UInt16)
    case unsupportedCredential(UInt16)
    case badSignature(String)
    case badMAC(String)
    case blankNode
    case noPrivateKey
    case notInGroup
    case epochMismatch
    case groupMismatch
    case duplicateIdentity(UInt64)
    case unrecognisedUser(UInt64)
    case unknownProposalReference
    case pathRequired
    case malformed(String)

    var description: String {
        switch self {
        case .keyDerivationFailed: "MLS: could not derive a key pair"
        case .unsupportedCipherSuite(let id): "MLS: ciphersuite \(id) is not the one DAVE uses"
        case .unsupportedVersion(let v): "MLS: protocol version \(v) is not 1.0"
        case .unsupportedWireFormat(let f): "MLS: wire format \(f) is not handled"
        case .unsupportedProposal(let t): "MLS: proposal type \(t) is not add or remove"
        case .unsupportedCredential(let t): "MLS: credential type \(t) is not basic"
        case .badSignature(let what): "MLS: signature does not verify on \(what)"
        case .badMAC(let what): "MLS: \(what) does not match"
        case .blankNode: "MLS: a node needed for this operation is blank"
        case .noPrivateKey: "MLS: no private key for the node this was encrypted to"
        case .notInGroup: "MLS: no established group"
        case .epochMismatch: "MLS: message is for a different epoch"
        case .groupMismatch: "MLS: message is for a different group"
        case .duplicateIdentity(let id): "MLS: user \(id) appears twice in the roster"
        case .unrecognisedUser(let id): "MLS: user \(id) is not in this call"
        case .unknownProposalReference: "MLS: commit references a proposal we never saw"
        case .pathRequired: "MLS: commit needs an update path and has none"
        case .malformed(let what): "MLS: \(what)"
        }
    }
}
