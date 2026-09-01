import CryptoKit
import Foundation

// MARK: - One member's view of one MLS group
//
// The state machine. Everything above this file is arithmetic; this is where a
// group is created, members are added and removed, commits are produced and
// consumed, and a new member is welcomed in.
//
// **Every transition is all-or-nothing.** A commit either produces a complete
// next state or throws, and the caller keeps the state it had. That is why the
// mutating operations build a fresh `MLSGroup` and return it rather than
// editing in place: half-applying a commit leaves a member in an epoch nobody
// else is in, and the only symptom is media that will not decrypt.
//
// The narrowing to DAVE is deliberate and stated where it happens: no
// pre-shared keys, no external commits, no re-initialisation, no private
// messages. Each of those is a path Discord's voice gateway never takes, and
// each would be untested code sitting inside a handshake.

struct MLSGroup {
    let groupID: [UInt8]
    private(set) var epoch: UInt64
    private(set) var tree: RatchetTree
    private(set) var treePrivate: TreeKEMPrivateState
    private(set) var extensions: [MLSExtension]
    private(set) var transcript: TranscriptHash
    private(set) var schedule: KeySchedule
    private(set) var leafIndex: LeafIndex
    let signatureKey: P256.Signing.PrivateKey

    /// Proposals received this epoch and not yet committed, by reference.
    private(set) var pendingProposals: [(reference: [UInt8], proposal: Proposal)] = []

    // MARK: Creating a group

    /// A group containing only us. Every DAVE session starts here, whether it
    /// ends up being the group everyone joins or is discarded when somebody
    /// else's commit wins.
    init(
        groupID: [UInt8],
        leafNode: LeafNode,
        encryptionKey: P256.KeyAgreement.PrivateKey,
        signatureKey: P256.Signing.PrivateKey,
        extensions: [MLSExtension]
    ) throws {
        self.groupID = groupID
        self.signatureKey = signatureKey
        self.extensions = extensions
        epoch = 0
        leafIndex = 0

        tree = RatchetTree(leafNode: leafNode)
        tree.refreshHashes()
        treePrivate = TreeKEMPrivateState(leafIndex: 0, leafPrivateKey: encryptionKey)
        transcript = TranscriptHash()

        // Epoch 0's init secret is fresh randomness, and its commit secret is
        // the zero string: there is no previous epoch to carry anything from.
        let context = try GroupContext(
            groupID: groupID,
            epoch: 0,
            treeHash: tree.rootHash,
            confirmedTranscriptHash: [],
            extensions: extensions
        ).marshalled()
        schedule = KeySchedule(
            initSecret: MLSCrypto.random(MLSCrypto.hashLength),
            commitSecret: [UInt8](repeating: 0, count: MLSCrypto.hashLength),
            groupContext: context,
            confirmedTranscriptHash: []
        )
        // A group of one has no commit behind it, so the interim transcript
        // hash is seeded from its own confirmation tag — the "virtual" tag of
        // an epoch that was never committed to.
        try transcript.advance(confirmed: [], confirmationTag: schedule.confirmationTag)
    }

    // MARK: Reading

    var groupContext: GroupContext {
        GroupContext(
            groupID: groupID,
            epoch: epoch,
            treeHash: tree.rootHash,
            confirmedTranscriptHash: transcript.confirmed,
            extensions: extensions
        )
    }

    /// The code first-party clients show for out-of-band comparison.
    var epochAuthenticator: [UInt8] { schedule.epochAuthenticator }

    /// Every member's user ID and signature key, by leaf.
    func roster() throws -> [UInt64: [UInt8]] {
        var result: [UInt64: [UInt8]] = [:]
        for leaf in tree.occupiedLeaves {
            guard let node = tree.leafNode(at: leaf) else { continue }
            guard let userID = node.credential.userID else {
                throw MLSError.malformed("a leaf credential that is not a snowflake")
            }
            guard result.updateValue(node.signatureKey, forKey: userID) == nil else {
                // Two leaves claiming one user is the shape a delivery service
                // would use to seat itself in a call, so it is fatal rather
                // than tolerated.
                throw MLSError.duplicateIdentity(userID)
            }
        }
        return result
    }

    /// `MLS-Exporter`, which is the entire interface DAVE has to this file.
    func export(label: String, context: [UInt8], length: Int) -> [UInt8] {
        schedule.export(label: label, context: context, length: length)
    }

    // MARK: Proposals

    /// The external senders the group's own extensions authorise.
    ///
    /// RFC 9420 puts them in a group context extension, and a proposal names
    /// which one signed it by index — so this is where the key to verify an
    /// external proposal comes from, not from whatever the caller happens to
    /// believe. DAVE's rule that there is exactly one, and that it is the voice
    /// gateway's, is checked once when the group is created or joined.
    func externalSenders() throws -> [ExternalSender] {
        guard let entry = extensions.first(.externalSenders) else { return [] }
        return try ExternalSendersExtension(unmarshalling: entry.data).senders
    }

    /// Validates and queues one proposal from the group's external sender.
    ///
    /// `validate` is the application's own admission rule, applied to each
    /// proposal before it is queued. **DAVE uses it to refuse an add for
    /// somebody the media session never announced**: the delivery service is
    /// trusted to relay what members already know, not to decide who is in the
    /// call. Keeping it a parameter is what stops this file from needing to
    /// know what a Discord user is.
    mutating func handleProposal(
        _ message: MLSMessage,
        validate: (Proposal) throws -> Void = { _ in }
    ) throws {
        guard case .publicMessage(let public_) = message else {
            throw MLSError.malformed("a proposal that is not a PublicMessage")
        }
        let content = public_.content
        guard content.groupID == groupID else { throw MLSError.groupMismatch }
        guard content.epoch == epoch else { throw MLSError.epochMismatch }
        guard case .proposal(let proposal) = content.body else {
            throw MLSError.malformed("a proposal frame that is not a proposal")
        }
        // Only an external sender proposes. A member-sent proposal is outside
        // DAVE's model entirely, and accepting one would let any participant
        // add or evict anybody.
        guard case .external(let index) = content.sender else {
            throw MLSError.malformed("a proposal from something other than an external sender")
        }
        let senders = try externalSenders()
        guard index < UInt32(senders.count) else {
            throw MLSError.malformed("a proposal from external sender \(index), which is not one")
        }

        let authenticated = AuthenticatedContent(
            wireFormat: .publicMessage, content: content, auth: public_.auth
        )
        guard MLSCrypto.verify(
            publicKey: senders[Int(index)].signatureKey,
            label: "FramedContentTBS",
            content: try Self.signedContent(
                wireFormat: .publicMessage, content: content, groupContext: nil
            ),
            signature: public_.auth.signature
        ) else { throw MLSError.badSignature("an external proposal") }

        switch proposal {
        case .add(let keyPackage):
            try Self.validate(keyPackage: keyPackage)
        case .remove(let leaf):
            guard tree.leafNode(at: leaf) != nil else {
                throw MLSError.malformed("a remove for a leaf that is already blank")
            }
        case .update:
            // Only add and remove are allowed from an external sender.
            throw MLSError.unsupportedProposal(ProposalType.update.rawValue)
        }
        try validate(proposal)

        let reference = try authenticated.reference()
        guard !pendingProposals.contains(where: { $0.reference == reference }) else { return }
        pendingProposals.append((reference, proposal))
    }

    /// Drops proposals the gateway has withdrawn.
    mutating func revokeProposals(_ references: [[UInt8]]) throws {
        for reference in references {
            guard let index = pendingProposals.firstIndex(where: { $0.reference == reference })
            else { throw MLSError.unknownProposalReference }
            pendingProposals.remove(at: index)
        }
    }

    mutating func clearPendingProposals() {
        pendingProposals.removeAll(keepingCapacity: false)
    }

    /// The structural checks §10.1 requires of any key package, before any
    /// application policy gets a say.
    static func validate(keyPackage: KeyPackage) throws {
        guard keyPackage.cipherSuite == MLSCrypto.cipherSuiteID else {
            throw MLSError.unsupportedCipherSuite(keyPackage.cipherSuite)
        }
        guard keyPackage.version == MLSCrypto.protocolVersion else {
            throw MLSError.unsupportedVersion(keyPackage.version)
        }
        guard case .keyPackage = keyPackage.leafNode.source else {
            throw MLSError.malformed("a key package whose leaf is not sourced from one")
        }
        try keyPackage.verifySignature()
        // A leaf in a key package signs without a group or an index, because it
        // does not have one yet.
        try keyPackage.leafNode.verifySignature(groupID: [], leafIndex: 0)
    }

    // MARK: Committing

    struct CommitOutput {
        /// The commit to send, as a `PublicMessage` in an `MLSMessage`.
        var commit: MLSMessage
        /// Present when the commit adds anybody.
        var welcome: Welcome?
        /// The state to adopt **only once the gateway echoes this commit back**.
        var next: MLSGroup
    }

    /// Builds a commit over every queued proposal.
    ///
    /// The resulting state is *not* adopted. Several members may commit at once
    /// and the voice gateway picks one; a client that moved epoch on its own
    /// commit and then lost the race would be alone in an epoch that never
    /// existed. `DAVESession` keeps this as a cached candidate and adopts it
    /// only when its own commit comes back as the winner.
    func commit() throws -> CommitOutput {
        var nextTree = tree
        var joiners: [(keyPackage: KeyPackage, leaf: LeafIndex)] = []
        var requiresPath = pendingProposals.isEmpty

        // §12.3's order: removes before adds, so a member being replaced frees
        // its leaf before the replacement is placed.
        for entry in pendingProposals {
            if case .remove(let leaf) = entry.proposal {
                requiresPath = true
                nextTree.blankPath(leaf)
            }
        }
        nextTree.truncate()
        for entry in pendingProposals {
            if case .add(let keyPackage) = entry.proposal {
                joiners.append((keyPackage, try nextTree.addLeaf(keyPackage.leafNode)))
            }
        }
        nextTree.refreshHashes()

        var nextPrivate = treePrivate
        nextPrivate.truncate(to: nextTree.leafCount)
        var path: UpdatePath?

        if requiresPath {
            let (state, _) = try nextTree.update(
                from: leafIndex,
                leafSecret: MLSCrypto.random(MLSCrypto.hashLength),
                groupID: groupID,
                signatureKey: signatureKey
            )
            nextPrivate = state
            // The context the path secrets are sealed under names the epoch we
            // are moving *to* and the tree as it will be — but the transcript
            // hash as it still is, because this commit is not in it yet.
            let context = try GroupContext(
                groupID: groupID,
                epoch: epoch + 1,
                treeHash: nextTree.rootHash,
                confirmedTranscriptHash: transcript.confirmed,
                extensions: extensions
            ).marshalled()
            path = try nextTree.encapsulate(
                nextPrivate, groupContext: context, excluding: joiners.map(\.leaf)
            )
        } else {
            // An add-only commit needs no path, and its commit secret is the
            // zero string. §12.4: the path "MAY be omitted if it covers at
            // least one proposal and none of them are of path-required types".
            nextPrivate.setCommitSecretToZero()
        }

        let commit = Commit(
            proposals: pendingProposals.map { .reference($0.reference) }, path: path
        )
        let content = FramedContent(
            groupID: groupID,
            epoch: epoch,
            sender: .member(leafIndex),
            authenticatedData: [],
            body: .commit(commit)
        )
        let signature = try MLSCrypto.sign(
            privateKey: signatureKey,
            label: "FramedContentTBS",
            content: try Self.signedContent(
                wireFormat: .publicMessage, content: content, groupContext: groupContext
            )
        )

        // The confirmed transcript hash covers this commit, and the next
        // epoch's key schedule covers that hash — so the tag can only be
        // computed after the state it confirms.
        var nextTranscript = transcript
        let confirmed = nextTranscript.nextConfirmed(try TranscriptHash.confirmedInput(
            wireFormat: .publicMessage, content: content, signature: signature
        ))
        let nextContext = try GroupContext(
            groupID: groupID,
            epoch: epoch + 1,
            treeHash: nextTree.rootHash,
            confirmedTranscriptHash: confirmed,
            extensions: extensions
        ).marshalled()
        let nextSchedule = KeySchedule(
            initSecret: schedule.initSecret,
            commitSecret: nextPrivate.commitSecret,
            groupContext: nextContext,
            confirmedTranscriptHash: confirmed
        )
        try nextTranscript.advance(
            confirmed: confirmed, confirmationTag: nextSchedule.confirmationTag
        )

        let auth = FramedContentAuthData(
            signature: signature, confirmationTag: nextSchedule.confirmationTag
        )
        let membershipTag = MLSCrypto.mac(
            key: schedule.membershipKey,
            message: try Self.membershipContent(content: content, auth: auth, group: self)
        )

        var next = self
        next.epoch = epoch + 1
        next.tree = nextTree
        next.treePrivate = nextPrivate
        next.transcript = nextTranscript
        next.schedule = nextSchedule
        next.pendingProposals = []

        let welcome = joiners.isEmpty ? nil : try next.makeWelcome(
            joiners: joiners, path: path, previous: nextPrivate
        )

        return CommitOutput(
            commit: .publicMessage(PublicMessage(
                content: content, auth: auth, membershipTag: membershipTag
            )),
            welcome: welcome,
            next: next
        )
    }

    /// Seals the group's state for each newly added member.
    private func makeWelcome(
        joiners: [(keyPackage: KeyPackage, leaf: LeafIndex)],
        path: UpdatePath?,
        previous: TreeKEMPrivateState
    ) throws -> Welcome {
        // **The tree is inlined.** DAVE requires it: a welcomed member has no
        // other way to obtain the ratchet tree, and the whitepaper says
        // committing members "must include an inline tree in their produced
        // welcome message".
        var info = GroupInfo(
            groupContext: groupContext,
            extensions: [MLSExtension(
                kind: .ratchetTree,
                data: try RatchetTreeExtension(nodes: tree.serialisedNodes).marshalled()
            )],
            confirmationTag: schedule.confirmationTag,
            signer: leafIndex
        )
        try info.sign(with: signatureKey)

        let key = MLSCrypto.expandWithLabel(
            secret: schedule.welcomeSecret, label: "key", context: [],
            length: MLSCrypto.aeadKeyLength
        )
        let nonce = MLSCrypto.expandWithLabel(
            secret: schedule.welcomeSecret, label: "nonce", context: [],
            length: MLSCrypto.aeadNonceLength
        )
        let sealed = try AES.GCM.seal(
            Data(try info.marshalled()),
            using: SymmetricKey(data: key),
            nonce: try AES.GCM.Nonce(data: nonce)
        )
        let encryptedGroupInfo = Array(sealed.ciphertext) + Array(sealed.tag)

        var secrets: [EncryptedGroupSecrets] = []
        secrets.reserveCapacity(joiners.count)
        for joiner in joiners {
            // A joiner that shares part of our path gets the secret at the node
            // where the two paths meet, which is how it can derive keys for the
            // subtree it landed in. With no path in the commit there is none.
            let pathSecret = path == nil ? nil : previous.sharedPathSecret(with: joiner.leaf)
            let groupSecrets = GroupSecrets(
                joinerSecret: schedule.joinerSecret, pathSecret: pathSecret
            )
            secrets.append(EncryptedGroupSecrets(
                newMember: try joiner.keyPackage.reference(),
                encryptedGroupSecrets: HPKECiphertext(try MLSCrypto.encrypt(
                    to: joiner.keyPackage.initKey,
                    label: "Welcome",
                    context: encryptedGroupInfo,
                    plaintext: try groupSecrets.marshalled()
                ))
            ))
        }
        return Welcome(secrets: secrets, encryptedGroupInfo: encryptedGroupInfo)
    }

    // MARK: Processing somebody else's commit

    /// Applies a commit and returns the next epoch's state.
    ///
    /// `cached` is our own pending commit, if this is it coming back — the
    /// committer cannot decrypt its own update path, so it adopts the state it
    /// already computed instead.
    func handleCommit(
        _ message: MLSMessage,
        cached: MLSGroup?,
        validate: (Proposal) throws -> Void = { _ in }
    ) throws -> MLSGroup {
        guard case .publicMessage(let public_) = message else {
            throw MLSError.malformed("a commit that is not a PublicMessage")
        }
        let content = public_.content
        guard content.groupID == groupID else { throw MLSError.groupMismatch }
        guard content.epoch == epoch else { throw MLSError.epochMismatch }
        guard case .commit(let commit) = content.body else {
            throw MLSError.malformed("a commit frame that is not a commit")
        }
        guard case .member(let sender) = content.sender else {
            throw MLSError.malformed("a commit from something other than a member")
        }
        guard let senderLeaf = tree.leafNode(at: sender) else { throw MLSError.blankNode }

        // If this is our own commit coming back, the state we already built is
        // the answer — and it is also the proof that what came back is what we
        // sent, since a modified commit would not re-serialise identically.
        if sender == leafIndex {
            guard let cached else {
                throw MLSError.malformed("our own commit came back with no cached state")
            }
            return cached
        }

        try verifyMemberAuthentication(
            public_, content: content, senderKey: senderLeaf.signatureKey
        )

        // Resolve every reference against what the gateway proposed to us.
        // §12.4.3 also forbids a commit from carrying proposals by value, which
        // is how a member would otherwise smuggle in one the gateway never saw.
        var proposals: [Proposal] = []
        proposals.reserveCapacity(commit.proposals.count)
        for entry in commit.proposals {
            guard case .reference(let reference) = entry else {
                throw MLSError.malformed("a commit carrying a proposal by value")
            }
            guard let match = pendingProposals.first(where: { $0.reference == reference })
            else { throw MLSError.unknownProposalReference }
            proposals.append(match.proposal)
        }

        var nextTree = tree
        var joiners: [LeafIndex] = []
        var requiresPath = proposals.isEmpty
        for proposal in proposals where proposal.requiresPath { requiresPath = true }

        for proposal in proposals {
            if case .remove(let leaf) = proposal { nextTree.blankPath(leaf) }
        }
        nextTree.truncate()
        for proposal in proposals {
            if case .add(let keyPackage) = proposal {
                try Self.validate(keyPackage: keyPackage)
                try validate(proposal)
                joiners.append(try nextTree.addLeaf(keyPackage.leafNode))
            }
        }
        nextTree.refreshHashes()

        var nextPrivate = treePrivate
        nextPrivate.truncate(to: nextTree.leafCount)

        if let path = commit.path {
            try nextTree.merge(from: sender, path: path)
            try path.leafNode.verifySignature(groupID: groupID, leafIndex: sender)
            guard nextTree.parentHashesValid() else {
                throw MLSError.badMAC("the commit's parent hash chain")
            }
            let context = try GroupContext(
                groupID: groupID,
                epoch: epoch + 1,
                treeHash: nextTree.rootHash,
                confirmedTranscriptHash: transcript.confirmed,
                extensions: extensions
            ).marshalled()
            try nextPrivate.decapsulate(
                path, from: sender, tree: nextTree, groupContext: context, excluding: joiners
            )
        } else {
            guard !requiresPath else { throw MLSError.pathRequired }
            nextPrivate.setCommitSecretToZero()
        }

        var nextTranscript = transcript
        let confirmed = nextTranscript.nextConfirmed(try TranscriptHash.confirmedInput(
            wireFormat: .publicMessage, content: content, signature: public_.auth.signature
        ))
        let nextContext = try GroupContext(
            groupID: groupID,
            epoch: epoch + 1,
            treeHash: nextTree.rootHash,
            confirmedTranscriptHash: confirmed,
            extensions: extensions
        ).marshalled()
        let nextSchedule = KeySchedule(
            initSecret: schedule.initSecret,
            commitSecret: nextPrivate.commitSecret,
            groupContext: nextContext,
            confirmedTranscriptHash: confirmed
        )

        // **The confirmation tag is the whole point of the epoch.** It says the
        // sender arrived at the same tree, the same transcript and the same
        // secrets we did. A mismatch means the group has forked, and there is
        // nothing to do with a forked group but leave it.
        guard let tag = public_.auth.confirmationTag,
              constantTimeEqual(tag, nextSchedule.confirmationTag)
        else { throw MLSError.badMAC("the commit's confirmation tag") }

        try nextTranscript.advance(confirmed: confirmed, confirmationTag: tag)

        var next = self
        next.epoch = epoch + 1
        next.tree = nextTree
        next.treePrivate = nextPrivate
        next.transcript = nextTranscript
        next.schedule = nextSchedule
        next.pendingProposals = []
        _ = try next.roster()   // rejects a commit that seats one user twice
        return next
    }

    private func verifyMemberAuthentication(
        _ message: PublicMessage, content: FramedContent, senderKey: [UInt8]
    ) throws {
        guard MLSCrypto.verify(
            publicKey: senderKey,
            label: "FramedContentTBS",
            content: try Self.signedContent(
                wireFormat: .publicMessage, content: content, groupContext: groupContext
            ),
            signature: message.auth.signature
        ) else { throw MLSError.badSignature("a member's commit") }

        guard let membershipTag = message.membershipTag else {
            throw MLSError.badMAC("a missing membership tag")
        }
        let expected = MLSCrypto.mac(
            key: schedule.membershipKey,
            message: try Self.membershipContent(content: content, auth: message.auth, group: self)
        )
        guard constantTimeEqual(membershipTag, expected) else {
            throw MLSError.badMAC("the membership tag")
        }
    }

    // MARK: Joining from a welcome

    /// Builds a group from a welcome addressed to `keyPackage`.
    ///
    /// This is the path a member takes when somebody else's commit added it,
    /// and it is the one where nothing can be taken on trust: the tree arrives
    /// from the committer, so its parent hashes, its leaf signatures, its root
    /// hash and the group info's own signature are all checked before any of it
    /// becomes state. The application's own admission rules — which external
    /// sender is expected, and who is allowed in the call — are checked by the
    /// caller against the group this produces.
    init(
        joining welcome: Welcome,
        keyPackage: KeyPackage,
        initKey: P256.KeyAgreement.PrivateKey,
        encryptionKey: P256.KeyAgreement.PrivateKey,
        signatureKey: P256.Signing.PrivateKey
    ) throws {
        guard welcome.cipherSuite == MLSCrypto.cipherSuiteID else {
            throw MLSError.unsupportedCipherSuite(welcome.cipherSuite)
        }
        let reference = try keyPackage.reference()
        guard let entry = welcome.secrets.first(where: { $0.newMember == reference }) else {
            throw MLSError.malformed("a welcome addressed to somebody else")
        }

        let groupSecrets = try GroupSecrets(unmarshalling: try MLSCrypto.decrypt(
            with: initKey,
            label: "Welcome",
            context: welcome.encryptedGroupInfo,
            sealed: entry.encryptedGroupSecrets.sealed
        ))
        guard groupSecrets.preSharedKeys.isEmpty else {
            throw MLSError.malformed("a welcome carrying pre-shared keys, which DAVE does not use")
        }

        // The group info is sealed under the welcome secret, which the joiner
        // secret we just decrypted produces.
        let welcomeSecret = MLSCrypto.deriveSecret(
            secret: MLSCrypto.extract(
                salt: groupSecrets.joinerSecret, ikm: KeySchedule.emptyPSKSecret
            ),
            label: "welcome"
        )
        let key = MLSCrypto.expandWithLabel(
            secret: welcomeSecret, label: "key", context: [], length: MLSCrypto.aeadKeyLength
        )
        let nonce = MLSCrypto.expandWithLabel(
            secret: welcomeSecret, label: "nonce", context: [],
            length: MLSCrypto.aeadNonceLength
        )
        guard welcome.encryptedGroupInfo.count > 16 else {
            throw MLSError.malformed("an encrypted group info too short to hold a tag")
        }
        let split = welcome.encryptedGroupInfo.count - 16
        let opened = try AES.GCM.open(
            try AES.GCM.SealedBox(
                nonce: try AES.GCM.Nonce(data: nonce),
                ciphertext: welcome.encryptedGroupInfo[..<split],
                tag: welcome.encryptedGroupInfo[split...]
            ),
            using: SymmetricKey(data: key)
        )
        let info = try GroupInfo(unmarshalling: [UInt8](opened))

        guard info.groupContext.cipherSuite == MLSCrypto.cipherSuiteID else {
            throw MLSError.unsupportedCipherSuite(info.groupContext.cipherSuite)
        }
        guard let treeExtension = info.extensions.first(.ratchetTree) else {
            throw MLSError.malformed("a welcome with no inline ratchet tree")
        }
        var importedTree = try RatchetTree(
            importing: try RatchetTreeExtension(unmarshalling: treeExtension.data).nodes
        )
        importedTree.refreshHashes()

        // Everything the committer could have lied about, checked in order.
        guard importedTree.rootHash == info.groupContext.treeHash else {
            throw MLSError.badMAC("the welcome's tree hash")
        }
        guard let signerLeaf = importedTree.leafNode(at: info.signer) else {
            throw MLSError.blankNode
        }
        try info.verifySignature(publicKey: signerLeaf.signatureKey)
        try importedTree.validateLeafSignatures(groupID: info.groupContext.groupID)
        guard importedTree.parentHashesValid() else {
            throw MLSError.badMAC("the welcome's parent hash chain")
        }

        guard let ourLeaf = importedTree.occupiedLeaves.first(where: {
            importedTree.leafNode(at: $0)?.encryptionKey == keyPackage.leafNode.encryptionKey
        }) else { throw MLSError.malformed("a welcome whose tree does not contain us") }

        groupID = info.groupContext.groupID
        epoch = info.groupContext.epoch
        extensions = info.groupContext.extensions
        tree = importedTree
        leafIndex = ourLeaf
        self.signatureKey = signatureKey

        treePrivate = TreeKEMPrivateState(leafIndex: ourLeaf, leafPrivateKey: encryptionKey)
        if let pathSecret = groupSecrets.pathSecret {
            // The secret sits at the node we share with the committer, and the
            // rest of our path derives up from there.
            treePrivate.implantMatching(
                tree,
                at: TreeMath.commonAncestor(
                    TreeMath.nodeIndex(ofLeaf: ourLeaf),
                    TreeMath.nodeIndex(ofLeaf: info.signer)
                ),
                secret: pathSecret
            )
        }

        transcript = TranscriptHash(
            confirmed: info.groupContext.confirmedTranscriptHash, interim: []
        )
        schedule = KeySchedule(
            joinerSecret: groupSecrets.joinerSecret,
            groupContext: try info.groupContext.marshalled(),
            confirmedTranscriptHash: info.groupContext.confirmedTranscriptHash
        )
        guard constantTimeEqual(schedule.confirmationTag, info.confirmationTag) else {
            throw MLSError.badMAC("the welcome's confirmation tag")
        }
        try transcript.advance(
            confirmed: info.groupContext.confirmedTranscriptHash,
            confirmationTag: info.confirmationTag
        )
    }

    /// The group must carry exactly the external sender the voice gateway gave
    /// us, and no other group extensions.
    static func validateGroupExtensions(
        _ extensions: [MLSExtension], externalSender: ExternalSender
    ) throws {
        guard let entry = extensions.first(.externalSenders) else {
            throw MLSError.malformed("a group with no external senders extension")
        }
        let senders = try ExternalSendersExtension(unmarshalling: entry.data).senders
        guard senders.count == 1 else {
            throw MLSError.malformed("a group with \(senders.count) external senders")
        }
        guard senders[0] == externalSender else {
            throw MLSError.malformed("a group whose external sender is not this voice gateway")
        }
    }

    // MARK: Serialising what gets signed

    /// `FramedContentTBS` — the content, its wire format, and the group context
    /// when a member or a new-member commit sent it.
    static func signedContent(
        wireFormat: WireFormat, content: FramedContent, groupContext: GroupContext?
    ) throws -> [UInt8] {
        var writer = TLSWriter(reserving: 512)
        writer.write(MLSCrypto.protocolVersion)
        writer.write(wireFormat.rawValue)
        try content.encode(into: &writer)
        switch content.sender {
        case .member, .newMemberCommit:
            guard let groupContext else {
                throw MLSError.malformed("a member frame signed without a group context")
            }
            try groupContext.encode(into: &writer)
        case .external, .newMemberProposal:
            break
        }
        return writer.bytes
    }

    /// `AuthenticatedContentTBM` — what the membership tag is a MAC over.
    private static func membershipContent(
        content: FramedContent, auth: FramedContentAuthData, group: MLSGroup
    ) throws -> [UInt8] {
        var writer = TLSWriter(reserving: 512)
        writer.writeRaw(try signedContent(
            wireFormat: .publicMessage, content: content, groupContext: group.groupContext
        ))
        try auth.encode(into: &writer, contentType: content.body.type)
        return writer.bytes
    }
}

/// Compares two MACs without leaking where they differ.
///
/// A tag comparison that returns early is a timing oracle, and both of the
/// places this is used — the confirmation tag and the membership tag — compare
/// a value from the network against one derived from a secret.
func constantTimeEqual(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
    guard lhs.count == rhs.count else { return false }
    var difference: UInt8 = 0
    for index in lhs.indices { difference |= lhs[index] ^ rhs[index] }
    return difference == 0
}
