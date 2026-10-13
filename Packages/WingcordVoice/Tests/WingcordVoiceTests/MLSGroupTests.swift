import CryptoKit
import Foundation
import Testing

@testable import WingcordVoice

// MARK: - A stand-in for the voice gateway
//
// The gateway is the MLS delivery *and* authentication service: it is the only
// external sender, and every add and remove in a DAVE call is a proposal it
// signs. Simulating it here is what makes the group tests real — they exercise
// the same external-proposal verification path a live call does, rather than
// reaching past it.

struct FakeGateway {
    let signingKey = MLSCrypto.generateSignatureKey()
    let userID: UInt64 = 0

    var externalSender: ExternalSender {
        ExternalSender(
            signatureKey: MLSCrypto.publicKeyBytes(signingKey),
            credential: Credential(userID: userID)
        )
    }

    var groupExtensions: [MLSExtension] {
        get throws {
            [MLSExtension(
                kind: .externalSenders,
                data: try ExternalSendersExtension(senders: [externalSender]).marshalled()
            )]
        }
    }

    /// One proposal, framed and signed the way the voice gateway frames one.
    func propose(_ proposal: Proposal, groupID: [UInt8], epoch: UInt64) throws -> MLSMessage {
        let content = FramedContent(
            groupID: groupID,
            epoch: epoch,
            sender: .external(0),
            authenticatedData: [],
            body: .proposal(proposal)
        )
        let signature = try MLSCrypto.sign(
            privateKey: signingKey,
            label: "FramedContentTBS",
            content: try MLSGroup.signedContent(
                wireFormat: .publicMessage, content: content, groupContext: nil
            )
        )
        return .publicMessage(PublicMessage(
            content: content,
            auth: FramedContentAuthData(signature: signature, confirmationTag: nil),
            // No membership tag: an external sender is not a member.
            membershipTag: nil
        ))
    }
}

/// One participant's key material and key package, as a client holds it.
struct FakeMember {
    let userID: UInt64
    let signingKey = MLSCrypto.generateSignatureKey()
    var encryptionKey = MLSCrypto.generateEncryptionKey()
    var initKey = MLSCrypto.generateEncryptionKey()

    init(userID: UInt64) { self.userID = userID }

    mutating func keyPackage() throws -> KeyPackage {
        encryptionKey = MLSCrypto.generateEncryptionKey()
        initKey = MLSCrypto.generateEncryptionKey()

        var leaf = LeafNode(
            encryptionKey: MLSCrypto.publicKeyBytes(encryptionKey),
            signatureKey: MLSCrypto.publicKeyBytes(signingKey),
            credential: Credential(userID: userID),
            capabilities: .dave,
            source: .keyPackage(Lifetime()),
            extensions: [],
            signature: []
        )
        try leaf.sign(with: signingKey, groupID: [], leafIndex: 0)

        var package = KeyPackage(
            initKey: MLSCrypto.publicKeyBytes(initKey), leafNode: leaf
        )
        try package.sign(with: signingKey)
        return package
    }

    func createGroup(groupID: [UInt8], extensions: [MLSExtension]) throws -> MLSGroup {
        var leaf = LeafNode(
            encryptionKey: MLSCrypto.publicKeyBytes(encryptionKey),
            signatureKey: MLSCrypto.publicKeyBytes(signingKey),
            credential: Credential(userID: userID),
            capabilities: .dave,
            source: .keyPackage(Lifetime()),
            extensions: [],
            signature: []
        )
        try leaf.sign(with: signingKey, groupID: [], leafIndex: 0)
        return try MLSGroup(
            groupID: groupID,
            leafNode: leaf,
            encryptionKey: encryptionKey,
            signatureKey: signingKey,
            extensions: extensions
        )
    }
}

// MARK: - The state machine

@Suite("MLS group")
struct MLSGroupTests {
    private let groupID: [UInt8] = [0, 1, 2, 3, 4, 5, 6, 7]

    /// The one interop test of the join path: a welcome another implementation
    /// produced, opened end to end.
    ///
    /// Two of the eight published vectors are shaped like a DAVE welcome — an
    /// inline ratchet tree and no pre-shared keys. The other six are asserted to
    /// be *refused*, and that is the point rather than a gap: a welcome with a
    /// PSK or without its tree is one this client is right to reject, because
    /// DAVE produces neither.
    @Test("A welcome from another implementation opens to the same epoch")
    func passiveJoin() throws {
        var joined = 0
        for vector in try Vectors.load("passive-client-welcome") {
            // The vectors wrap both in an `MLSMessage`. Discord's voice gateway
            // does not — opcode 26 carries a bare `KeyPackage` and opcode 30 a
            // bare `Welcome` — so both framings get exercised, here and in
            // `DAVEOpcode`.
            guard case .keyPackage(let keyPackage) = try MLSMessage(
                unmarshalling: vector.hex("key_package")
            ), case .welcome(let welcome) = try MLSMessage(
                unmarshalling: vector.hex("welcome")
            ) else {
                Issue.record("a passive-client vector that is not a key package and a welcome")
                continue
            }
            let hasPSKs = !vector.array("external_psks").isEmpty
            let hasExternalTree = vector["ratchet_tree"] is String

            let group = try? MLSGroup(
                joining: welcome,
                keyPackage: keyPackage,
                initKey: try P256.KeyAgreement.PrivateKey(
                    rawRepresentation: vector.hex("init_priv")
                ),
                encryptionKey: try P256.KeyAgreement.PrivateKey(
                    rawRepresentation: vector.hex("encryption_priv")
                ),
                signatureKey: try P256.Signing.PrivateKey(
                    rawRepresentation: vector.hex("signature_priv")
                )
            )

            if hasPSKs || hasExternalTree {
                #expect(group == nil, "a welcome DAVE never produces should be refused")
                continue
            }

            guard let group else {
                Issue.record("failed to join a plain welcome")
                continue
            }
            // The epoch authenticator is the whole group state condensed to
            // thirty-two bytes. Matching it means the tree, the transcript and
            // every secret agree with the implementation that built them.
            #expect(group.epochAuthenticator == vector.hex("initial_epoch_authenticator"))
            joined += 1
        }
        #expect(joined == 2, "both plain welcomes should have been joined")
    }

    /// The smallest real call: a direct message between two people.
    @Test("Two members reach the same epoch, and export the same media secrets")
    func twoPartyCall() throws {
        let gateway = FakeGateway()
        let alice = FakeMember(userID: 111)
        var bob = FakeMember(userID: 222)
        let recognised: Set<UInt64> = [alice.userID, bob.userID]

        var alicesGroup = try alice.createGroup(
            groupID: groupID, extensions: try gateway.groupExtensions
        )
        let bobsPackage = try bob.keyPackage()

        // The gateway broadcasts an add for the pending member.
        try alicesGroup.handleProposal(
            try gateway.propose(
                .add(bobsPackage), groupID: groupID, epoch: alicesGroup.epoch
            ),
            validate: validator(recognised)
        )
        let output = try alicesGroup.commit()
        #expect(output.welcome != nil, "a commit with an add must carry a welcome")

        // The gateway echoes the winning commit; Alice adopts her cached state.
        alicesGroup = try alicesGroup.handleCommit(output.commit, cached: output.next)
        let bobsGroup = try MLSGroup(
            joining: try #require(output.welcome),
            keyPackage: bobsPackage,
            initKey: bob.initKey,
            encryptionKey: bob.encryptionKey,
            signatureKey: bob.signingKey
        )

        #expect(alicesGroup.epoch == 1)
        #expect(bobsGroup.epoch == 1)
        try expectAgreement([alicesGroup, bobsGroup], users: [alice.userID, bob.userID])
    }

    /// Three people, then one leaves — which is the case that forces an update
    /// path and therefore exercises TreeKEM in both directions.
    @Test("A third member joins and a member leaves, and the rest stay in step")
    func threePartyCall() throws {
        let gateway = FakeGateway()
        let alice = FakeMember(userID: 111)
        var bob = FakeMember(userID: 222)
        var carol = FakeMember(userID: 333)
        let recognised: Set<UInt64> = [alice.userID, bob.userID, carol.userID]

        var alicesGroup = try alice.createGroup(
            groupID: groupID, extensions: try gateway.groupExtensions
        )

        // Bob joins.
        let bobsPackage = try bob.keyPackage()
        try alicesGroup.handleProposal(
            try gateway.propose(.add(bobsPackage), groupID: groupID, epoch: alicesGroup.epoch),
            validate: validator(recognised)
        )
        var output = try alicesGroup.commit()
        alicesGroup = try alicesGroup.handleCommit(output.commit, cached: output.next)
        var bobsGroup = try MLSGroup(
            joining: try #require(output.welcome),
            keyPackage: bobsPackage,
            initKey: bob.initKey,
            encryptionKey: bob.encryptionKey,
            signatureKey: bob.signingKey
        )

        // Carol joins. Alice commits again; Bob has to follow the same commit.
        let carolsPackage = try carol.keyPackage()
        let carolAdd = try gateway.propose(
            .add(carolsPackage), groupID: groupID, epoch: alicesGroup.epoch
        )
        try alicesGroup.handleProposal(carolAdd, validate: validator(recognised))
        try bobsGroup.handleProposal(carolAdd, validate: validator(recognised))

        output = try alicesGroup.commit()
        let carolsWelcome = try #require(output.welcome)
        alicesGroup = try alicesGroup.handleCommit(output.commit, cached: output.next)
        bobsGroup = try bobsGroup.handleCommit(
            output.commit, cached: nil, validate: validator(recognised)
        )
        var carolsGroup = try MLSGroup(
            joining: carolsWelcome,
            keyPackage: carolsPackage,
            initKey: carol.initKey,
            encryptionKey: carol.encryptionKey,
            signatureKey: carol.signingKey
        )

        #expect(alicesGroup.epoch == 2)
        try expectAgreement(
            [alicesGroup, bobsGroup, carolsGroup],
            users: [alice.userID, bob.userID, carol.userID]
        )

        // Bob leaves. A remove needs an update path, so this is the branch where
        // Carol has to decrypt a path secret out of somebody else's commit.
        let bobsLeaf = try #require(
            alicesGroup.tree.occupiedLeaves.first {
                alicesGroup.tree.leafNode(at: $0)?.credential.userID == bob.userID
            }
        )
        let removal = try gateway.propose(
            .remove(bobsLeaf), groupID: groupID, epoch: alicesGroup.epoch
        )
        try alicesGroup.handleProposal(removal, validate: validator(recognised))
        try carolsGroup.handleProposal(removal, validate: validator(recognised))

        output = try alicesGroup.commit()
        #expect(output.welcome == nil, "a removal adds nobody, so there is no welcome")
        alicesGroup = try alicesGroup.handleCommit(output.commit, cached: output.next)
        carolsGroup = try carolsGroup.handleCommit(
            output.commit, cached: nil, validate: validator(recognised)
        )

        #expect(alicesGroup.epoch == 3)
        try expectAgreement(
            [alicesGroup, carolsGroup], users: [alice.userID, carol.userID]
        )
        // And Bob's old state cannot follow: the epoch he holds is behind, and
        // the secrets he can still derive are the previous epoch's.
        #expect(bobsGroup.epoch == 2)
        #expect(bobsGroup.epochAuthenticator != alicesGroup.epochAuthenticator)
    }

    @Test("A commit whose confirmation tag was altered is refused")
    func tamperedCommit() throws {
        let gateway = FakeGateway()
        let alice = FakeMember(userID: 111)
        var bob = FakeMember(userID: 222)
        let recognised: Set<UInt64> = [alice.userID, bob.userID]

        var alicesGroup = try alice.createGroup(
            groupID: groupID, extensions: try gateway.groupExtensions
        )
        let bobsPackage = try bob.keyPackage()
        try alicesGroup.handleProposal(
            try gateway.propose(.add(bobsPackage), groupID: groupID, epoch: 0),
            validate: validator(recognised)
        )
        let output = try alicesGroup.commit()
        let originalAlice = alicesGroup
        alicesGroup = try alicesGroup.handleCommit(output.commit, cached: output.next)
        var bobsGroup = try MLSGroup(
            joining: try #require(output.welcome),
            keyPackage: bobsPackage,
            initKey: bob.initKey,
            encryptionKey: bob.encryptionKey,
            signatureKey: bob.signingKey
        )

        // Alice commits an empty change; Bob is handed it with one bit moved.
        let second = try alicesGroup.commit()
        guard case .publicMessage(var message) = second.commit else {
            Issue.record("a commit that is not a public message")
            return
        }
        message.auth.confirmationTag?[0] ^= 0x01
        #expect(throws: (any Error).self) {
            _ = try bobsGroup.handleCommit(.publicMessage(message), cached: nil)
        }

        // A proposal for the wrong epoch is refused too — that is how a replayed
        // frame from a previous epoch would present.
        _ = originalAlice
        #expect(throws: (any Error).self) {
            try bobsGroup.handleProposal(
                try gateway.propose(.remove(0), groupID: self.groupID, epoch: 99)
            )
        }
    }

    /// The delivery service is not trusted to decide who is in the call.
    @Test("An add for somebody the call never announced is refused")
    func unannouncedMember() throws {
        let gateway = FakeGateway()
        let alice = FakeMember(userID: 111)
        var stranger = FakeMember(userID: 999)

        var group = try alice.createGroup(
            groupID: groupID, extensions: try gateway.groupExtensions
        )
        #expect(throws: (any Error).self) {
            try group.handleProposal(
                try gateway.propose(
                    .add(try stranger.keyPackage()), groupID: self.groupID, epoch: 0
                ),
                validate: self.validator([alice.userID])
            )
        }
        #expect(group.pendingProposals.isEmpty)
    }

    /// A proposal signed by anybody but the group's external sender.
    @Test("A proposal from an impostor gateway does not verify")
    func forgedProposal() throws {
        let real = FakeGateway()
        let impostor = FakeGateway()
        let alice = FakeMember(userID: 111)
        var bob = FakeMember(userID: 222)

        var group = try alice.createGroup(
            groupID: groupID, extensions: try real.groupExtensions
        )
        #expect(throws: (any Error).self) {
            try group.handleProposal(
                try impostor.propose(
                    .add(try bob.keyPackage()), groupID: self.groupID, epoch: 0
                ),
                validate: self.validator([alice.userID, bob.userID])
            )
        }
    }

    // MARK: Helpers

    /// DAVE's own admission rule, as `DAVESession` applies it.
    private func validator(_ recognised: Set<UInt64>) -> (Proposal) throws -> Void {
        { proposal in
            guard case .add(let keyPackage) = proposal else { return }
            guard let userID = keyPackage.leafNode.credential.userID,
                  recognised.contains(userID)
            else { throw MLSError.unrecognisedUser(0) }
        }
    }

    /// Every member must agree on the epoch, on who is in the room, and on the
    /// media secret exported for each of them — which is the only thing DAVE
    /// actually takes out of MLS.
    private func expectAgreement(_ groups: [MLSGroup], users: [UInt64]) throws {
        guard let first = groups.first else { return }
        for group in groups.dropFirst() {
            #expect(group.epoch == first.epoch)
            #expect(group.epochAuthenticator == first.epochAuthenticator)
            #expect(try group.roster().keys.sorted() == (try first.roster().keys.sorted()))
        }
        #expect(try first.roster().keys.sorted() == users.sorted())

        for user in users {
            var context = TLSWriter(reserving: 8)
            context.write(user.littleEndian)
            let expected = first.export(
                label: "Discord Secure Frames v0", context: context.bytes, length: 16
            )
            #expect(expected.count == 16)
            for group in groups.dropFirst() {
                #expect(
                    group.export(
                        label: "Discord Secure Frames v0", context: context.bytes, length: 16
                    ) == expected,
                    "media base secret for user \(user)"
                )
            }
        }
    }
}
