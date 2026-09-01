import Foundation

// MARK: - The epoch key schedule
//
// One commit moves the group to a new epoch, and this is what the new epoch's
// secrets are made of. RFC 9420 §8, read top to bottom:
//
//     init_secret[n-1] ──salt──┐
//     commit_secret ────ikm────┴─> Extract
//                                     └─> ExpandWithLabel(., "joiner", ctx)
//                                            └─> joiner_secret ──salt──┐
//                        psk_secret (all zero here) ────────────ikm────┴─> Extract
//                                            ├─> DeriveSecret(., "welcome")
//                                            └─> ExpandWithLabel(., "epoch", ctx)
//                                                   └─> epoch_secret
//                                                          ├─> DeriveSecret(., <label>)
//                                                          └─> DeriveSecret(., "init")
//
// **`Extract` takes the salt from the top of that diagram and the input keying
// material from the left**, which is the reverse of how HMAC's own arguments
// read. Getting it backwards produces a key schedule that is entirely
// self-consistent and shares no secret with anybody.
//
// DAVE never injects a pre-shared key, so `psk_secret` is the all-zero string
// of one hash length — which is what §8.4 defines it to be for an empty list,
// not a shortcut.

struct KeySchedule {
    /// Carried into the next epoch, and nothing else may be.
    let initSecret: [UInt8]
    let joinerSecret: [UInt8]
    let welcomeSecret: [UInt8]
    let senderDataSecret: [UInt8]
    let encryptionSecret: [UInt8]
    let exporterSecret: [UInt8]
    let confirmationKey: [UInt8]
    let membershipKey: [UInt8]
    let resumptionPSK: [UInt8]
    /// What first-party clients show as the call's verification code.
    let epochAuthenticator: [UInt8]

    /// The epoch's own MAC over the transcript. Every member computes it
    /// independently, and a commit whose tag does not match is a commit that
    /// took somebody else somewhere different.
    let confirmationTag: [UInt8]

    /// An empty PSK list is a zero string, per §8.4.
    static var emptyPSKSecret: [UInt8] { [UInt8](repeating: 0, count: MLSCrypto.hashLength) }

    /// Advances from the previous epoch's init secret.
    init(
        initSecret previous: [UInt8],
        commitSecret: [UInt8],
        groupContext: [UInt8],
        pskSecret: [UInt8] = KeySchedule.emptyPSKSecret,
        confirmedTranscriptHash: [UInt8]
    ) {
        let extracted = MLSCrypto.extract(salt: previous, ikm: commitSecret)
        let joiner = MLSCrypto.expandWithLabel(
            secret: extracted, label: "joiner", context: groupContext,
            length: MLSCrypto.hashLength
        )
        self.init(
            joinerSecret: joiner,
            pskSecret: pskSecret,
            groupContext: groupContext,
            confirmedTranscriptHash: confirmedTranscriptHash
        )
    }

    /// Starts from a joiner secret, which is what a welcome hands a new member
    /// instead of the epoch's history.
    init(
        joinerSecret: [UInt8],
        pskSecret: [UInt8] = KeySchedule.emptyPSKSecret,
        groupContext: [UInt8],
        confirmedTranscriptHash: [UInt8]
    ) {
        self.joinerSecret = joinerSecret
        let member = MLSCrypto.extract(salt: joinerSecret, ikm: pskSecret)
        welcomeSecret = MLSCrypto.deriveSecret(secret: member, label: "welcome")

        let epochSecret = MLSCrypto.expandWithLabel(
            secret: member, label: "epoch", context: groupContext,
            length: MLSCrypto.hashLength
        )
        senderDataSecret = MLSCrypto.deriveSecret(secret: epochSecret, label: "sender data")
        encryptionSecret = MLSCrypto.deriveSecret(secret: epochSecret, label: "encryption")
        exporterSecret = MLSCrypto.deriveSecret(secret: epochSecret, label: "exporter")
        confirmationKey = MLSCrypto.deriveSecret(secret: epochSecret, label: "confirm")
        membershipKey = MLSCrypto.deriveSecret(secret: epochSecret, label: "membership")
        resumptionPSK = MLSCrypto.deriveSecret(secret: epochSecret, label: "resumption")
        epochAuthenticator = MLSCrypto.deriveSecret(
            secret: epochSecret, label: "authentication"
        )
        initSecret = MLSCrypto.deriveSecret(secret: epochSecret, label: "init")

        confirmationTag = MLSCrypto.mac(
            key: confirmationKey, message: confirmedTranscriptHash
        )
    }

    /// `MLS-Exporter(Label, Context, Length)` — §8.5.
    ///
    /// This is the whole interface between MLS and DAVE: the per-sender media
    /// key ratchets are exported through it and nothing else crosses the line.
    func export(label: String, context: [UInt8], length: Int) -> [UInt8] {
        MLSCrypto.expandWithLabel(
            secret: MLSCrypto.deriveSecret(secret: exporterSecret, label: label),
            label: "exported",
            context: MLSCrypto.hash(context),
            length: length
        )
    }
}

// MARK: - Transcript hashes

/// The running hash of every commit the group has accepted.
///
/// It is folded into the `GroupContext`, so two members who processed different
/// histories cannot agree on an epoch even if they somehow agreed on a tree —
/// which is precisely the fork the confirmation tag is there to catch.
struct TranscriptHash {
    private(set) var confirmed: [UInt8]
    private(set) var interim: [UInt8]

    init(confirmed: [UInt8] = [], interim: [UInt8] = []) {
        self.confirmed = confirmed
        self.interim = interim
    }

    /// `confirmed_transcript_hash_[n] = Hash(interim_[n-1] || ConfirmedTranscriptHashInput)`
    static func confirmedInput(
        wireFormat: WireFormat, content: FramedContent, signature: [UInt8]
    ) throws -> [UInt8] {
        var writer = TLSWriter(reserving: 512)
        writer.write(wireFormat.rawValue)
        try content.encode(into: &writer)
        try writer.writeOpaque(signature)
        return writer.bytes
    }

    func nextConfirmed(_ input: [UInt8]) -> [UInt8] {
        MLSCrypto.hash(interim + input)
    }

    /// `interim_transcript_hash_[n] = Hash(confirmed_[n] || confirmation_tag)`
    static func interim(after confirmed: [UInt8], confirmationTag: [UInt8]) throws -> [UInt8] {
        var writer = TLSWriter(reserving: 64)
        try writer.writeOpaque(confirmationTag)
        return MLSCrypto.hash(confirmed + writer.bytes)
    }

    mutating func advance(confirmed value: [UInt8], confirmationTag: [UInt8]) throws {
        confirmed = value
        interim = try Self.interim(after: value, confirmationTag: confirmationTag)
    }
}

// MARK: - The sender ratchet

/// RFC 9420 §9.1's symmetric hash ratchet, which is what DAVE derives its media
/// keys from — `MlsKeyRatchet` in Discord's own library is this and nothing
/// added.
///
/// A generation's key is derived from the ratchet secret at that generation,
/// and the secret is then ratcheted forward. **Keys are cached rather than
/// destroyed on use**: media arrives out of order and a receiver that discarded
/// generation *n* the moment it saw *n+1* would drop every reordered packet.
/// `erase` is how a caller gives up a generation deliberately.
struct MLSHashRatchet {
    /// How far ahead of the highest generation seen the ratchet will walk in
    /// one call.
    ///
    /// Not a tuning knob: the generation comes off the wire as the top byte of
    /// an attacker-controllable nonce, and a ratchet that will happily step
    /// sixteen million times on request is a denial of service sitting inside a
    /// packet handler. Discord's own library caps the same walk at 250.
    static let maximumGenerationGap: UInt32 = 250

    private var nextSecret: [UInt8]
    private var nextGeneration: UInt32 = 0
    /// The *ratchet secret* per generation, not the key. Keys and nonces are
    /// both derived from it, so caching the secret keeps one cache instead of
    /// two and leaves nothing stored that nothing reads.
    private var cache: [UInt32: [UInt8]] = [:]

    init(baseSecret: [UInt8]) {
        nextSecret = baseSecret
    }

    /// `ratchet_secret_[j]`, walking forward as far as needed.
    ///
    /// `nil` for a generation already erased or beyond the gap — asking for one
    /// is a replayed, very late, or hostile frame, and none of those is an
    /// error worth propagating past the packet that carried it.
    private mutating func secret(for generation: UInt32) -> [UInt8]? {
        if let cached = cache[generation] { return cached }
        guard generation >= nextGeneration,
              generation - nextGeneration < Self.maximumGenerationGap
        else { return nil }

        while nextGeneration <= generation {
            let current = nextGeneration
            cache[current] = nextSecret
            nextSecret = MLSCrypto.deriveTreeSecret(
                secret: nextSecret, label: "secret", generation: current,
                length: MLSCrypto.hashLength
            )
            nextGeneration = current + 1
        }
        return cache[generation]
    }

    /// The AEAD key for a generation. This is the one DAVE asks for, and it
    /// asks once per generation rather than once per frame.
    mutating func key(
        for generation: UInt32, length: Int = MLSCrypto.aeadKeyLength
    ) -> [UInt8]? {
        secret(for: generation).map {
            MLSCrypto.deriveTreeSecret(
                secret: $0, label: "key", generation: generation, length: length
            )
        }
    }

    /// The AEAD nonce for a generation. MLS's own message framing uses it;
    /// DAVE does not, because its nonce is the frame's own counter.
    mutating func nonce(for generation: UInt32) -> [UInt8]? {
        secret(for: generation).map {
            MLSCrypto.deriveTreeSecret(
                secret: $0, label: "nonce", generation: generation,
                length: MLSCrypto.aeadNonceLength
            )
        }
    }

    mutating func erase(_ generation: UInt32) {
        cache[generation] = nil
    }
}
