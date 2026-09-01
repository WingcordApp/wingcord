import Foundation
import Synchronization
import Testing

@testable import WingcordVoice

// MARK: - The whole handshake, both ends
//
// Two `DAVESession`s and a stand-in for the voice gateway, driven through the
// real opcode sequence: key packages, the external sender, add proposals, a
// commit, a welcome, readiness, execute — and then media that only decrypts if
// every one of those steps agreed.
//
// This is the test that would have caught the thing the whole feature is
// blocked on. Everything below it is verified against published vectors; this
// is what says the pieces are wired together in the order the protocol expects.

// The suite is **serialised** because one test installs the process-wide
// `VoiceTrace.sink`, and a second DAVE test running beside it would interleave
// lines that are not the ones under assertion.
@Suite("DAVE session", .serialized)
struct DAVESessionTests {
    private let channelID: UInt64 = 127_121_515_263_701_768
    private let alice: UInt64 = 111
    private let bob: UInt64 = 222
    private let carol: UInt64 = 333

    /// Runs the initial group creation between however many members, and hands
    /// back their sessions once every one of them is end-to-end encrypted.
    private func establish(_ users: [UInt64]) throws -> [UInt64: DAVESession] {
        let gateway = FakeGateway()
        var sessions: [UInt64: DAVESession] = [:]
        var keyPackages: [UInt64: KeyPackage] = [:]

        for user in users {
            let session = DAVESession(protocolVersion: 1, userID: user, channelID: channelID)
            session.recognise(users: Set(users))
            sessions[user] = session
            keyPackages[user] = try session.makeKeyPackage()
            try session.setExternalSender(gateway.externalSender)
        }

        // The gateway broadcasts an add for every pending member to every other
        // pending member, and each of them answers with a commit. Only the
        // first commit wins, so the rest are discarded — which is exactly the
        // race a real call has when several people join at once.
        var winner: (user: UInt64, commit: MLSMessage, welcome: Welcome?)?
        for user in users {
            guard let session = sessions[user] else { continue }
            let others = users.filter { $0 != user }.compactMap { keyPackages[$0] }
            guard !others.isEmpty else { continue }

            let proposals = try others.map {
                try gateway.propose(.add($0), groupID: session.groupID, epoch: 0)
            }
            guard let output = try session.processProposals(.append(proposals)) else {
                Issue.record("a member with pending adds produced no commit")
                continue
            }
            guard case .commitWelcome(let commit, let welcome) = output else { continue }
            if winner == nil { winner = (user, commit, welcome) }
        }

        let won = try #require(winner)
        let raw = try won.commit.marshalled()

        // The winner sees its own commit come back; everybody else is welcomed.
        for user in users {
            guard let session = sessions[user] else { continue }
            let outcome: DAVESession.Outcome
            if user == won.user {
                outcome = session.processCommit(won.commit, raw: raw, transitionID: 1)
            } else {
                outcome = session.processWelcome(try #require(won.welcome), transitionID: 1)
            }
            #expect(outcome == .ready(transitionID: 1), "member \(user) was not ready")
        }

        // And when everyone has reported ready, the gateway says go.
        for session in sessions.values { session.executeTransition(id: 1) }
        return sessions
    }

    @Test("A one-to-one call establishes, and media only decrypts under it")
    func directMessageCall() throws {
        let sessions = try establish([alice, bob])
        let alices = try #require(sessions[alice])
        let bobs = try #require(sessions[bob])

        #expect(alices.isEstablished)
        #expect(bobs.isEstablished)
        #expect(alices.members() == [alice, bob])

        // Both arrived at the same group, which is what the verification code
        // exists for people to check out loud.
        guard case .encrypted(let alicesCode) = alices.status,
              case .encrypted(let bobsCode) = bobs.status
        else {
            Issue.record("a call that established but does not say it is encrypted")
            return
        }
        #expect(alicesCode == bobsCode)
        #expect(alicesCode.count == 30)

        // Media, end to end.
        let frame: [UInt8] = [0x78] + (0..<60).map { UInt8(truncatingIfNeeded: $0 &* 5 &+ 1) }
        let sealed = try #require(alices.encryptor.encrypt(frame, codec: .opus))
        #expect(sealed != frame, "a frame that was not actually encrypted")

        let decryptor = try #require(bobs.decryptor(for: alice))
        #expect(decryptor.decrypt(sealed, isAudio: true) == frame)

        // And in the other direction.
        let reply = try #require(bobs.encryptor.encrypt(frame, codec: .opus))
        #expect(try #require(alices.decryptor(for: bob)).decrypt(reply, isAudio: true) == frame)

        // Somebody outside the group cannot read it. This is the guarantee the
        // whole feature exists to make, so it is asserted rather than assumed.
        let outsider = DAVESession(protocolVersion: 1, userID: carol, channelID: channelID)
        outsider.recognise(users: [alice, bob, carol])
        _ = try outsider.makeKeyPackage()
        #expect(outsider.decryptor(for: alice) == nil)
    }

    /// The trace exists to say *where* a handshake stopped, and it only earns
    /// that if it fires on every step, in the order the protocol runs them. So
    /// the order is asserted rather than trusted: a diagnostic that silently
    /// stopped reporting one step would send the next reader looking at the
    /// wrong layer, which is worse than having no trace at all.
    @Test("The trace records the handshake in the order the protocol runs it")
    func traceRecordsTheHandshakeInOrder() throws {
        let captured = Mutex<[String]>([])
        VoiceTrace.sink = { line in captured.withLock { $0.append(line) } }
        defer { VoiceTrace.sink = nil }

        _ = try establish([alice, bob])

        // An ordered subsequence, not an exact list: two sessions are driven
        // here and their lines interleave, which is also what a real call's
        // trace looks like.
        let steps = [
            "dave session v1",
            "dave key package built",
            "dave external sender accepted",
            "dave proposals append=",
            "dave commit built over",
            "dave epoch=1 members=2",
            "dave execute transition 1",
            "dave sending under epoch 1",
        ]
        let lines = captured.withLock { $0 }
        var rest = lines[...]
        for step in steps {
            guard let found = rest.firstIndex(where: { $0.hasPrefix(step) }) else {
                Issue.record("the trace never reached \"\(step)\"; it said \(lines)")
                return
            }
            rest = rest[rest.index(after: found)...]
        }
    }

    @Test("A three-way call establishes and every pair can hear every other")
    func groupCall() throws {
        let sessions = try establish([alice, bob, carol])
        let frame: [UInt8] = [0x78, 1, 2, 3, 4, 5, 6, 7, 8]

        for sender in [alice, bob, carol] {
            let sending = try #require(sessions[sender])
            #expect(sending.members() == [alice, bob, carol])
            let sealed = try #require(sending.encryptor.encrypt(frame, codec: .opus))

            for receiver in [alice, bob, carol] where receiver != sender {
                let receiving = try #require(sessions[receiver])
                let decryptor = try #require(
                    receiving.decryptor(for: sender), "no decryptor for \(sender)"
                )
                #expect(
                    decryptor.decrypt(sealed, isAudio: true) == frame,
                    "\(receiver) could not hear \(sender)"
                )
            }
        }

        // Everybody's view of the group is the same.
        let codes = Set([alice, bob, carol].compactMap { user -> String? in
            guard case .encrypted(let code)? = sessions[user]?.status else { return nil }
            return code
        })
        #expect(codes.count == 1, "members disagree on the epoch authenticator")
    }

    /// Before the group exists there is nothing to encrypt with, and the honest
    /// answer is to drop rather than to send in the clear.
    @Test("Nothing is sent unencrypted while the group is still being made")
    func nothingLeaksBeforeEstablishment() throws {
        let session = DAVESession(protocolVersion: 1, userID: alice, channelID: channelID)
        session.recognise(users: [alice, bob])
        #expect(session.status == .establishing)
        // Version 1 means the encoder's output is not fit to send until there
        // is a key, and `nil` is what a caller must not turn into a plain frame.
        #expect(session.encryptor.encrypt([1, 2, 3, 4], codec: .opus) == nil)
    }

    @Test("Version zero is transport-only, and says so")
    func transportOnly() {
        let session = DAVESession(protocolVersion: 0, userID: alice, channelID: channelID)
        #expect(session.status == .transportOnly)
        #expect(session.encryptor.isPassthrough)
        #expect(session.encryptor.encrypt([1, 2, 3, 4], codec: .opus) == [1, 2, 3, 4])
    }

    /// A downgrade is announced, prepared, and only then executed.
    @Test("A downgrade to version zero turns encryption off in the right order")
    func downgrade() throws {
        let sessions = try establish([alice, bob])
        let alices = try #require(sessions[alice])
        #expect(!alices.encryptor.isPassthrough)

        // Opcode 21: the receive side starts accepting plain frames now, but
        // the send side keeps encrypting until the gateway says to stop.
        #expect(alices.prepareTransition(id: 7, protocolVersion: 0))
        #expect(!alices.encryptor.isPassthrough, "sending in the clear too early")

        alices.executeTransition(id: 7)
        #expect(alices.encryptor.isPassthrough)
        #expect(alices.status == .transportOnly)
    }

    /// Opcode 24 with epoch 1 means the group is being re-created from nothing.
    @Test("A prepare-epoch of one resets the session and asks for a key package")
    func epochReset() throws {
        let sessions = try establish([alice, bob])
        let alices = try #require(sessions[alice])
        #expect(alices.isEstablished)

        #expect(alices.prepareEpoch(1, protocolVersion: 1))
        #expect(!alices.isEstablished)
        #expect(alices.status == .establishing)

        // A later epoch that is not one is a version change, not a reset.
        #expect(!alices.prepareEpoch(4, protocolVersion: 1))
    }

    /// An `execute_transition` for something never announced must not move keys.
    @Test("An unannounced transition is ignored rather than executed")
    func unknownTransition() throws {
        let sessions = try establish([alice, bob])
        let alices = try #require(sessions[alice])
        let before = alices.status
        alices.executeTransition(id: 4_242)
        #expect(alices.status == before)
        #expect(!alices.encryptor.isPassthrough)
    }

    /// The gateway relays who is in the call; it does not get to decide.
    @Test("An add for a user the call never announced is refused")
    func unannouncedUser() throws {
        let gateway = FakeGateway()
        let session = DAVESession(protocolVersion: 1, userID: alice, channelID: channelID)
        session.recognise(users: [alice])
        _ = try session.makeKeyPackage()
        try session.setExternalSender(gateway.externalSender)

        var stranger = FakeMember(userID: 999)
        #expect(throws: (any Error).self) {
            _ = try session.processProposals(.append([
                try gateway.propose(
                    .add(try stranger.keyPackage()),
                    groupID: session.groupID,
                    epoch: 0
                ),
            ]))
        }
    }

    /// The epoch authenticator, rendered the way Discord renders it.
    @Test("The verification code is thirty digits in six groups of five")
    func verificationCode() {
        let authenticator = (0..<32).map { UInt8($0) }
        let code = DAVESession.displayCode(authenticator)
        #expect(code.count == 30)
        let isAllDigits = code.allSatisfy { $0.isNumber }
        #expect(isAllDigits)

        // Each group is five bytes read big-endian, modulo 100000, zero padded.
        // The first group is 00 01 02 03 04 = 16909060, and 16909060 % 100000
        // is 9060 — which pads to five digits rather than being shown as four.
        #expect(code == "090606058512110636351516066685")
        // Too little input for the code asked for is empty, not a short code.
        #expect(DAVESession.displayCode([1, 2, 3]) == "")
    }
}
