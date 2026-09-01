import Foundation
import Testing

@testable import WingcordVoice

@Suite("MLS key schedule")
struct KeyScheduleTests {
    /// Walks the published five-epoch chain: each epoch's init secret feeds the
    /// next, so a single wrong derivation anywhere breaks every epoch after it.
    @Test("Every epoch secret matches, across the whole published chain")
    func epochChain() throws {
        for vector in try Vectors.load("key-schedule") {
            var initSecret = vector.hex("initial_init_secret")

            for (index, epoch) in vector.array("epochs").enumerated() {
                guard let epoch = epoch as? [String: Any] else { continue }
                let context = epoch.hex("group_context")

                let schedule = KeySchedule(
                    initSecret: initSecret,
                    commitSecret: epoch.hex("commit_secret"),
                    groupContext: context,
                    pskSecret: epoch.hex("psk_secret"),
                    confirmedTranscriptHash: epoch.hex("confirmed_transcript_hash")
                )

                #expect(schedule.joinerSecret == epoch.hex("joiner_secret"), "joiner @\(index)")
                #expect(schedule.welcomeSecret == epoch.hex("welcome_secret"), "welcome @\(index)")
                #expect(
                    schedule.senderDataSecret == epoch.hex("sender_data_secret"),
                    "sender data @\(index)"
                )
                #expect(
                    schedule.encryptionSecret == epoch.hex("encryption_secret"),
                    "encryption @\(index)"
                )
                #expect(
                    schedule.exporterSecret == epoch.hex("exporter_secret"), "exporter @\(index)"
                )
                #expect(
                    schedule.confirmationKey == epoch.hex("confirmation_key"),
                    "confirmation @\(index)"
                )
                #expect(
                    schedule.membershipKey == epoch.hex("membership_key"), "membership @\(index)"
                )
                #expect(
                    schedule.resumptionPSK == epoch.hex("resumption_psk"), "resumption @\(index)"
                )
                #expect(
                    schedule.epochAuthenticator == epoch.hex("epoch_authenticator"),
                    "epoch authenticator @\(index)"
                )
                #expect(schedule.initSecret == epoch.hex("init_secret"), "init @\(index)")

                // The exporter is the one derivation DAVE actually uses.
                //
                // The vector's `label` is a *string* field that happens to hold
                // hex text, not a hex-encoded byte string like everything else
                // in these files — so it is passed through verbatim. MLS's own
                // labels and DAVE's are all ASCII, which is why the library
                // takes a `String` here at all.
                let exporter = epoch.dict("exporter")
                #expect(
                    schedule.export(
                        label: exporter.string("label"),
                        context: exporter.hex("context"),
                        length: exporter.int("length")
                    ) == exporter.hex("secret"),
                    "exported secret @\(index)"
                )

                // Starting from the joiner secret instead — the path a welcomed
                // member takes — has to land in exactly the same place.
                let welcomed = KeySchedule(
                    joinerSecret: epoch.hex("joiner_secret"),
                    pskSecret: epoch.hex("psk_secret"),
                    groupContext: context,
                    confirmedTranscriptHash: epoch.hex("confirmed_transcript_hash")
                )
                #expect(welcomed.epochAuthenticator == schedule.epochAuthenticator)
                #expect(welcomed.initSecret == schedule.initSecret)

                initSecret = schedule.initSecret
            }
        }
    }

    @Test("An empty PSK list is a zero string of one hash length")
    func emptyPSK() {
        #expect(KeySchedule.emptyPSKSecret.count == 32)
        #expect(KeySchedule.emptyPSKSecret.allSatisfy { $0 == 0 })
    }
}

@Suite("MLS transcript hashes")
struct TranscriptHashTests {
    @Test("A commit advances both transcript hashes, and the tag follows")
    func advance() throws {
        for vector in try Vectors.load("transcript-hashes") {
            let content = try AuthenticatedContent(
                unmarshalling: vector.hex("authenticated_content")
            )
            var transcript = TranscriptHash(
                confirmed: [], interim: vector.hex("interim_transcript_hash_before")
            )

            let input = try TranscriptHash.confirmedInput(
                wireFormat: content.wireFormat,
                content: content.content,
                signature: content.auth.signature
            )
            let confirmed = transcript.nextConfirmed(input)
            #expect(confirmed == vector.hex("confirmed_transcript_hash_after"))

            // The confirmation tag is a MAC over the confirmed hash, and the
            // interim hash then folds the tag back in.
            let tag = MLSCrypto.mac(
                key: vector.hex("confirmation_key"), message: confirmed
            )
            try transcript.advance(confirmed: confirmed, confirmationTag: tag)
            #expect(transcript.interim == vector.hex("interim_transcript_hash_after"))
        }
    }
}

@Suite("MLS sender ratchet")
struct HashRatchetTests {
    /// The ratchet DAVE derives every media key from, against the working
    /// group's published keys and nonces.
    ///
    /// The secret tree that produces each leaf's base secret is walked *here*
    /// rather than in the library: MLS uses it to key its own message framing
    /// and DAVE does not — its base secret comes from the exporter instead — so
    /// building it in `WingcordVoice` would be a whole derivation nothing in the
    /// app can reach. What is shared with DAVE is the ratchet at the bottom, and
    /// that is what these vectors pin.
    @Test("Keys and nonces match the published ratchets, in and out of order")
    func publishedRatchets() throws {
        for vector in try Vectors.load("secret-tree") {
            let leaves = vector.array("leaves")
            let leafCount = TreeMath.fullLeafCount(UInt32(leaves.count))

            for (index, leaf) in leaves.enumerated() {
                guard let steps = leaf as? [Any] else { continue }
                let base = secretTreeLeaf(
                    root: vector.hex("encryption_secret"),
                    leaf: LeafIndex(index),
                    leafCount: leafCount
                )

                // Two ratchets per leaf, from the same leaf secret.
                var application = MLSHashRatchet(baseSecret: MLSCrypto.expandWithLabel(
                    secret: base, label: "application", context: [],
                    length: MLSCrypto.hashLength
                ))
                var handshake = MLSHashRatchet(baseSecret: MLSCrypto.expandWithLabel(
                    secret: base, label: "handshake", context: [],
                    length: MLSCrypto.hashLength
                ))

                for step in steps {
                    guard let step = step as? [String: Any] else { continue }
                    let generation = step.uint32("generation")
                    #expect(
                        application.key(for: generation) == step.hex("application_key"),
                        "application key, leaf \(index) generation \(generation)"
                    )
                    #expect(
                        application.nonce(for: generation) == step.hex("application_nonce"),
                        "application nonce, leaf \(index) generation \(generation)"
                    )
                    #expect(
                        handshake.key(for: generation) == step.hex("handshake_key"),
                        "handshake key, leaf \(index) generation \(generation)"
                    )
                    #expect(
                        handshake.nonce(for: generation) == step.hex("handshake_nonce"),
                        "handshake nonce, leaf \(index) generation \(generation)"
                    )
                }
            }
        }
    }

    /// Walks the secret tree from its root down to one leaf, per RFC 9420 §9.
    private func secretTreeLeaf(
        root: [UInt8], leaf: LeafIndex, leafCount: UInt32
    ) -> [UInt8] {
        let target = TreeMath.nodeIndex(ofLeaf: leaf)
        // In a one-member group the root *is* the leaf, so there is nothing to
        // descend and the encryption secret is the leaf secret.
        guard target != TreeMath.root(leaves: leafCount) else { return root }

        // Root first: the direct path runs leaf-to-root, so it is reversed, the
        // root dropped, and the leaf itself appended.
        var descent = TreeMath.directPath(target, leaves: leafCount).reversed().dropFirst()
            .map { $0 }
        descent.append(target)

        var secret = root
        var current = TreeMath.root(leaves: leafCount)
        for child in descent {
            let side = child == TreeMath.left(current) ? "left" : "right"
            secret = MLSCrypto.expandWithLabel(
                secret: secret, label: "tree", context: Array(side.utf8),
                length: MLSCrypto.hashLength
            )
            current = child
        }
        return secret
    }

    @Test("A ratchet is deterministic, forward-only, and forgets on request")
    func ratchetBehaviour() {
        // A ratchet is deterministic, walks forward only, and refuses a
        // generation it has been told to forget.
        var ratchet = MLSHashRatchet(baseSecret: [UInt8](repeating: 0xAB, count: 32))
        let first = ratchet.key(for: 0)
        let third = ratchet.key(for: 2)
        #expect(first != nil)
        #expect(third != nil)
        #expect(first != third)
        // Re-asking is stable, which is what lets reordered frames decrypt.
        #expect(ratchet.key(for: 0) == first)
        #expect(ratchet.nonce(for: 0)?.count == 12)

        ratchet.erase(0)
        #expect(ratchet.key(for: 0) == nil)
        #expect(ratchet.key(for: 2) == third)

        // A second ratchet from the same seed agrees, which is the property the
        // sender and receiver rely on.
        var mirror = MLSHashRatchet(baseSecret: [UInt8](repeating: 0xAB, count: 32))
        #expect(mirror.key(for: 2) == third)
    }

    /// The generation comes off the wire as the top byte of the frame's nonce,
    /// so it is attacker-chosen. Walking to it would be millions of derivations
    /// inside a packet handler.
    @Test("A wild generation is refused rather than walked to")
    func generationGap() {
        let gap = MLSHashRatchet.maximumGenerationGap

        var fresh = MLSHashRatchet(baseSecret: [UInt8](repeating: 1, count: 32))
        #expect(fresh.key(for: gap - 1) != nil)

        var refuses = MLSHashRatchet(baseSecret: [UInt8](repeating: 1, count: 32))
        #expect(refuses.key(for: gap) == nil)
        #expect(refuses.key(for: 1_000_000) == nil)
        // Refusing a wild generation must not have moved the ratchet.
        #expect(refuses.key(for: 0) != nil)

        // The gap is measured from where the ratchet has reached, not from zero.
        var advanced = MLSHashRatchet(baseSecret: [UInt8](repeating: 1, count: 32))
        #expect(advanced.key(for: 10) != nil)
        #expect(advanced.key(for: 10 + gap) != nil)
        #expect(advanced.key(for: 10 + gap + gap + 1) == nil)
    }
}
