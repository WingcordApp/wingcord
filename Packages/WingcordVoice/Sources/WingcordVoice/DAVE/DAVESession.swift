import CryptoKit
import Foundation

// MARK: - One call's end-to-end encryption
//
// The state machine that sits between the voice gateway's DAVE opcodes and the
// MLS group underneath. It owns the group, the transitions, and the per-sender
// media ratchets that `DAVEEncryptor` and `DAVEDecryptor` run on.
//
// **The shape of a DAVE call, once through:**
//
//   ← op 4    session description carries `dave_protocol_version`
//   → op 26   our key package
//   ← op 25   the gateway's external sender  → a pending group of one
//   ← op 27   an add proposal for each pending member
//   → op 28   our commit, and a welcome for anyone it adds
//   ← op 29   the commit that won, or
//   ← op 30   a welcome, if somebody else's commit won and it added us
//   → op 23   ready for the transition
//   ← op 22   execute it
//
// Two rules decide when keys actually change, and they are not the same rule:
//
// - **Receive keys change when the commit is processed.** Media encrypted under
//   the previous epoch is still in flight, so the old ratchets are kept for ten
//   seconds alongside the new ones.
// - **Send keys change on `execute_transition` and not before.** Everybody has
//   to be holding the new receive keys before anybody starts sending under
//   them, and that opcode is the gateway saying they are.
//
// Getting those two the same way round produces a call where the first second
// after every join is silence.

final class DAVESession {
    /// What the app shows about the call's protection.
    enum Status: Equatable {
        /// Transport encryption only — a stage channel, or a member who cannot
        /// do DAVE.
        case transportOnly
        /// Negotiated, but the group is not established yet.
        case establishing
        /// End-to-end encrypted, with a verification code for the epoch.
        case encrypted(verificationCode: String)
    }

    /// The exporter label DAVE derives every media key under.
    private static let mediaSecretLabel = "Discord Secure Frames v0"

    let userID: UInt64
    /// The MLS group id: the **channel**'s snowflake, big-endian.
    ///
    /// Not the guild's, and not the identify payload's `server_id`. A Go Live
    /// stream is a separate media session with its own group, keyed by the
    /// media session id rather than the channel — see `VoiceEngine`.
    let groupID: [UInt8]

    private(set) var protocolVersion: UInt16
    private(set) var group: MLSGroup?
    /// The group of one we create before anybody has committed, and which is
    /// discarded the moment a real group is established.
    private var pendingGroup: MLSGroup?
    /// The state our own commit would produce, held until the gateway says our
    /// commit won.
    private var cachedCommit: (message: [UInt8], next: MLSGroup)?

    private var externalSender: ExternalSender?
    private var recognisedUsers: Set<UInt64> = []

    /// The identity this device presents for the call.
    ///
    /// **Ephemeral, and deliberately so.** A persistent key would let Discord
    /// and other participants correlate this device across calls, and the
    /// protocol makes persistence an explicit opt-in for that reason. Nothing
    /// here is stored.
    private let signatureKey = MLSCrypto.generateSignatureKey()
    private var encryptionKey = MLSCrypto.generateEncryptionKey()
    private var initKey = MLSCrypto.generateEncryptionKey()
    private var currentKeyPackage: KeyPackage?

    /// Transitions the gateway has announced but not yet told us to execute.
    private var pendingTransitions: [UInt16: UInt16] = [:]

    let encryptor = DAVEEncryptor()
    /// One decryptor per remote sender: the media key is per-sender, so a
    /// shared one would have to guess whose key to try.
    private var decryptors: [UInt64: DAVEDecryptor] = [:]

    init(protocolVersion: UInt16, userID: UInt64, channelID: UInt64) {
        self.protocolVersion = protocolVersion
        self.userID = userID
        var writer = TLSWriter(reserving: 8)
        writer.write(channelID)
        groupID = writer.bytes
        encryptor.setPassthrough(protocolVersion == 0)
        VoiceTrace.write("dave session v\(protocolVersion) group=\(channelID)")
    }

    // MARK: What the app sees

    var status: Status {
        guard protocolVersion > 0 else { return .transportOnly }
        guard let group else { return .establishing }
        return .encrypted(
            verificationCode: DAVESession.displayCode(group.epochAuthenticator)
        )
    }

    var isEstablished: Bool { group != nil }

    /// Everybody the established group contains.
    func members() -> Set<UInt64> {
        (try? group?.roster().keys).map(Set.init) ?? []
    }

    func decryptor(for userID: UInt64) -> DAVEDecryptor? { decryptors[userID] }

    /// Every remote sender's transform, for the receive path to route packets
    /// through. Handed over as a whole map after each epoch change rather than
    /// one at a time: the receive path takes them under one lock, and a
    /// half-applied roster is a moment where somebody's media is dropped for no
    /// reason.
    var receiveTransforms: [UInt64: DAVEDecryptor] { decryptors }

    /// The media session's own list of who is present.
    ///
    /// **The gateway is not trusted to decide this.** An add proposal for
    /// somebody who never appeared in `clients_connect` is refused, which is
    /// what stops the delivery service seating an extra listener in a call.
    func recognise(users: Set<UInt64>) {
        recognisedUsers.formUnion(users)
        recognisedUsers.insert(userID)
    }

    func forget(user: UInt64) {
        recognisedUsers.remove(user)
        decryptors[user] = nil
    }

    // MARK: Key packages

    /// A fresh key package, and the private halves that go with it.
    ///
    /// Key packages are single-use: the gateway drops the cached one as soon as
    /// it sees a welcome for it, and a member that reuses one would be adding a
    /// second appearance of itself to the group.
    func makeKeyPackage() throws -> KeyPackage {
        encryptionKey = MLSCrypto.generateEncryptionKey()
        initKey = MLSCrypto.generateEncryptionKey()

        var leaf = LeafNode(
            encryptionKey: MLSCrypto.publicKeyBytes(encryptionKey),
            signatureKey: MLSCrypto.publicKeyBytes(signatureKey),
            credential: Credential(userID: userID),
            capabilities: .dave,
            source: .keyPackage(Lifetime()),
            extensions: [],
            signature: []
        )
        try leaf.sign(with: signatureKey, groupID: [], leafIndex: 0)

        var package = KeyPackage(initKey: MLSCrypto.publicKeyBytes(initKey), leafNode: leaf)
        try package.sign(with: signatureKey)
        currentKeyPackage = package

        // With the external sender already known, this is also the moment the
        // local group of one can exist.
        try makePendingGroup()
        VoiceTrace.write(
            "dave key package built, pending group "
            + (pendingGroup == nil ? "waits for the external sender" : "created")
        )
        return package
    }

    /// Throws away everything and starts over, for a re-created group.
    func reset(protocolVersion: UInt16) {
        VoiceTrace.write("dave reset to v\(protocolVersion)")
        self.protocolVersion = protocolVersion
        group = nil
        pendingGroup = nil
        cachedCommit = nil
        currentKeyPackage = nil
        pendingTransitions.removeAll()
        for decryptor in decryptors.values { decryptor.reset() }
        encryptor.setRatchet(nil)
        encryptor.setPassthrough(protocolVersion == 0)
    }

    // MARK: The gateway's external sender

    /// Opcode 25. Until this arrives there is nothing to build a group with.
    func setExternalSender(_ sender: ExternalSender) throws {
        guard group == nil else {
            // Changing the authority mid-group would invalidate every proposal
            // already accepted under the old one.
            throw MLSError.malformed("an external sender after the group was established")
        }
        externalSender = sender
        try makePendingGroup()
        VoiceTrace.write(
            "dave external sender accepted, pending group "
            + (pendingGroup == nil ? "waits for a key package" : "created")
        )
    }

    private func makePendingGroup() throws {
        guard group == nil, let externalSender, let keyPackage = currentKeyPackage else {
            return
        }
        // The leaf a group of one starts from is the one in our key package,
        // so the two agree on the encryption key we hold the private half of.
        pendingGroup = try MLSGroup(
            groupID: groupID,
            leafNode: keyPackage.leafNode,
            encryptionKey: encryptionKey,
            signatureKey: signatureKey,
            extensions: [MLSExtension(
                kind: .externalSenders,
                data: try ExternalSendersExtension(senders: [externalSender]).marshalled()
            )]
        )
    }

    // MARK: Proposals and commits

    /// Opcode 27, and the commit it produces for opcode 28.
    ///
    /// Returns `nil` when there is nothing to commit — no local group yet, or
    /// the proposals were all revocations that emptied the queue.
    func processProposals(_ proposals: DAVEProposals) throws -> DAVEOutbound? {
        guard var working = group ?? pendingGroup else {
            // "If a member receives proposals from the voice gateway while they
            // do not have a local group, the proposals are ignored."
            return nil
        }

        switch proposals {
        case .append(let messages):
            VoiceTrace.write("dave proposals append=\(messages.count)")
            for message in messages {
                try working.handleProposal(message, validate: admit)
            }
        case .revoke(let references):
            VoiceTrace.write("dave proposals revoke=\(references.count)")
            try working.revokeProposals(references)
        }

        guard !working.pendingProposals.isEmpty else {
            store(working)
            VoiceTrace.write("dave nothing left to commit")
            return nil
        }

        let output = try working.commit()
        store(working)
        cachedCommit = (try output.commit.marshalled(), output.next)
        VoiceTrace.write(
            "dave commit built over \(working.pendingProposals.count) proposals, "
            + "welcome=\(output.welcome != nil)"
        )
        return .commitWelcome(commit: output.commit, welcome: output.welcome)
    }

    /// DAVE's admission rule, applied to every proposal before it is queued.
    private func admit(_ proposal: Proposal) throws {
        guard case .add(let keyPackage) = proposal else { return }
        guard let user = keyPackage.leafNode.credential.userID else {
            throw MLSError.malformed("a key package credential that is not a snowflake")
        }
        guard recognisedUsers.contains(user) else { throw MLSError.unrecognisedUser(user) }
    }

    private func store(_ working: MLSGroup) {
        if group != nil { group = working } else { pendingGroup = working }
    }

    /// What processing a commit or welcome asks the caller to do next.
    enum Outcome: Equatable {
        /// Report readiness for this transition with opcode 23.
        case ready(transitionID: UInt16)
        /// Transition zero is (re)initialisation and has already been executed;
        /// there is nothing to report and nothing to wait for.
        case executed
        /// Nothing to do — the message was not ours to act on.
        case ignored
        /// The message could not be processed. Tell the gateway (opcode 31),
        /// reset, and send a new key package.
        case invalid(transitionID: UInt16)
    }

    /// Records the transition a commit or welcome opened, and reports what the
    /// caller owes the gateway.
    ///
    /// **The transition has to be recorded here.** A commit's transition is
    /// never announced by opcode 21 or 24 — the id arrives on the commit
    /// itself — so a session that only recorded the announced ones would refuse
    /// the `execute_transition` that follows every single epoch change.
    private func open(transition id: UInt16) -> Outcome {
        pendingTransitions[id] = protocolVersion
        guard id != 0 else {
            executeTransition(id: 0)
            return .executed
        }
        return .ready(transitionID: id)
    }

    /// Opcode 29.
    func processCommit(_ message: MLSMessage, raw: [UInt8], transitionID: UInt16) -> Outcome {
        do {
            guard let working = group ?? pendingGroup else { return .ignored }

            // **An unestablished group accepts only its own commit.** Until
            // epoch 1 every member's local group has them at leaf zero, so
            // somebody else's commit would verify against the wrong tree
            // entirely. If theirs won, a welcome is on its way instead.
            if group == nil {
                guard let cached = cachedCommit, cached.message == raw else {
                    VoiceTrace.write("dave commit \(transitionID) is not ours; awaiting a welcome")
                    return .ignored
                }
                adopt(cached.next)
                return open(transition: transitionID)
            }

            let next = try working.handleCommit(
                message,
                cached: cachedCommit.map(\.next),
                validate: admit
            )
            adopt(next)
            return open(transition: transitionID)
        } catch {
            VoiceTrace.fault("dave commit \(transitionID) refused: \(error)")
            return .invalid(transitionID: transitionID)
        }
    }

    /// Opcode 30.
    func processWelcome(_ welcome: Welcome, transitionID: UInt16) -> Outcome {
        do {
            guard group == nil, let keyPackage = currentKeyPackage,
                  let externalSender
            else { return .ignored }

            let joined = try MLSGroup(
                joining: welcome,
                keyPackage: keyPackage,
                initKey: initKey,
                encryptionKey: encryptionKey,
                signatureKey: signatureKey
            )
            // MLS proved the tree is internally consistent and signed. These
            // two are DAVE's own rules on top of it: the gateway we were told
            // about is the group's authority, and everybody in the tree is
            // somebody the media session announced.
            try MLSGroup.validateGroupExtensions(
                joined.extensions, externalSender: externalSender
            )
            for user in try joined.roster().keys where !recognisedUsers.contains(user) {
                throw MLSError.unrecognisedUser(user)
            }

            adopt(joined)
            return open(transition: transitionID)
        } catch {
            VoiceTrace.fault("dave welcome \(transitionID) refused: \(error)")
            return .invalid(transitionID: transitionID)
        }
    }

    /// Adopts a new epoch and re-keys every **receive** path.
    ///
    /// The send path is deliberately untouched: it changes on
    /// `executeTransition`, once the gateway says everyone can decrypt.
    private func adopt(_ next: MLSGroup) {
        group = next
        pendingGroup = nil
        cachedCommit = nil

        // **One roster read, not two.** It is a walk of the ratchet tree, and
        // this runs on every epoch change — which is every join and every part.
        let members = Set((try? next.roster().keys).map(Array.init) ?? [])
        VoiceTrace.write(
            "dave epoch=\(next.epoch) members=\(members.count) leaf=\(next.leafIndex) "
            + "code=\(DAVESession.displayCode(next.epochAuthenticator))"
        )

        for user in members {
            guard user != userID else { continue }
            let decryptor = decryptors[user] ?? {
                let made = DAVEDecryptor(userID: user)
                decryptors[user] = made
                return made
            }()
            decryptor.transition(
                to: ratchet(for: user, in: next), retaining: DAVE.keyRetention
            )
            decryptor.setPassthrough(false, retaining: DAVE.keyRetention)
        }
        // Anybody no longer in the group keeps their decryptor only long enough
        // for media already in flight.
        for (user, decryptor) in decryptors where !members.contains(user) {
            decryptor.transition(to: nil, retaining: DAVE.keyRetention)
        }
    }

    /// The per-sender media ratchet, which is the only thing DAVE takes out of
    /// MLS.
    ///
    /// The context is the sender's user id **little-endian**, which is not the
    /// endianness their credential uses in the same protocol. That asymmetry is
    /// Discord's, it is in the specification twice, and it was corrected once in
    /// the whitepaper's own changelog — so it is written out here rather than
    /// left to a reader to assume it matches the credential.
    private func ratchet(for user: UInt64, in group: MLSGroup) -> MLSHashRatchet {
        var context = TLSWriter(reserving: 8)
        context.write(user.littleEndian)
        return MLSHashRatchet(baseSecret: group.export(
            label: Self.mediaSecretLabel,
            context: context.bytes,
            length: MLSCrypto.aeadKeyLength
        ))
    }

    // MARK: Transitions

    /// Opcode 21. Returns whether the caller should report readiness.
    func prepareTransition(id: UInt16, protocolVersion version: UInt16) -> Bool {
        VoiceTrace.write("dave prepare transition \(id) to v\(version)")
        pendingTransitions[id] = version
        // **Transition zero is a (re)initialisation and executes at once.** It
        // is how the gateway tells a sole remaining member to adopt the fresh
        // local group it just asked for.
        if id == 0 {
            executeTransition(id: 0)
            return false
        }
        if version == 0 {
            // Downgrading: start accepting plain frames now, because the far
            // end may stop encrypting as soon as it hears we are ready.
            for decryptor in decryptors.values {
                decryptor.setPassthrough(true, retaining: DAVE.keyRetention)
            }
        }
        return true
    }

    /// Opcode 24. Returns `true` when a new key package has to be sent, which
    /// is the signal that the group is being created or re-created.
    func prepareEpoch(_ epoch: UInt64, protocolVersion version: UInt16) -> Bool {
        VoiceTrace.write("dave prepare epoch \(epoch) at v\(version)")
        guard epoch == 1 else {
            protocolVersion = version
            return false
        }
        reset(protocolVersion: version)
        return version > 0
    }

    /// Opcode 22. The send path changes here and nowhere else.
    func executeTransition(id: UInt16) {
        guard let version = pendingTransitions.removeValue(forKey: id) else {
            // A transition we never prepared. Ignoring it is right: acting on
            // it would mean changing keys on a schedule we did not agree to.
            VoiceTrace.fault("dave execute for a transition \(id) we never prepared")
            return
        }
        VoiceTrace.write("dave execute transition \(id) at v\(version)")
        protocolVersion = version

        guard version > 0 else {
            encryptor.setRatchet(nil)
            encryptor.setPassthrough(true)
            for decryptor in decryptors.values {
                decryptor.setPassthrough(true, retaining: DAVE.keyRetention)
            }
            return
        }
        guard let group else {
            // Told to send under an epoch we never reached. Everything we
            // encode from here is dropped rather than sent in the clear, and
            // this line is the only warning of it.
            VoiceTrace.fault("dave execute \(id) with no established group; sending stays off")
            return
        }
        encryptor.setRatchet(ratchet(for: userID, in: group))
        encryptor.setPassthrough(false)
        VoiceTrace.write("dave sending under epoch \(group.epoch)")
    }

    // MARK: The verification code

    /// The epoch authenticator as Discord displays it: thirty digits in six
    /// groups of five, for reading aloud to somebody on the other end.
    ///
    /// Each group is five bytes of the authenticator read big-endian, taken
    /// modulo 100000 and zero-padded — Signal's displayable-code algorithm with
    /// the group size Discord chose.
    static func displayCode(_ authenticator: [UInt8], digits: Int = 30, groupSize: Int = 5) -> String {
        let groups = digits / groupSize
        guard groupSize < 8, digits % groupSize == 0,
              authenticator.count >= groups * groupSize
        else { return "" }

        var code = ""
        code.reserveCapacity(digits)
        var modulus: UInt64 = 1
        for _ in 0..<groupSize { modulus *= 10 }

        for group in 0..<groups {
            var value: UInt64 = 0
            for offset in 0..<groupSize {
                value = value << 8 | UInt64(authenticator[group * groupSize + offset])
            }
            let digitsInGroup = String(value % modulus)
            code += String(repeating: "0", count: groupSize - digitsInGroup.count) + digitsInGroup
        }
        return code
    }
}
