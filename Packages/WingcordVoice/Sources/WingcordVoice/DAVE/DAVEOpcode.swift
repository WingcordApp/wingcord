import Foundation

// MARK: - DAVE's own voice gateway opcodes
//
// Opcodes 21 to 31, added to the voice gateway for the protocol. Five of them
// are JSON like the rest of that socket; six are **binary**, which is the first
// thing to get right — the voice gateway is otherwise a text-only protocol, and
// this client learned the hard way that a frame sent in the wrong form is
// accepted by TCP and answered by nothing.
//
// The framing is asymmetric, and the asymmetry is real rather than an accident
// of the specification:
//
//   server → client   uint16 sequence_number, uint8 opcode, payload
//   client → server                          uint8 opcode, payload
//
// The sequence number is the same one v8's heartbeat acknowledges, so a binary
// frame moves `seq_ack` exactly like a JSON one does. A client that reads the
// opcode from byte 0 of an inbound frame reads the top half of a sequence
// number instead, and every DAVE message looks like a different opcode.
//
// One more discrepancy, and it is settled in favour of what ships: the
// whitepaper's struct for opcode 26 says `MLSMessage key_package_message`, but
// Discord's own `libdave` marshals a **bare `KeyPackage`** and every working
// third-party client sends one. Opcode 30's welcome is bare in the same way.
// The `MLSMessage` envelope appears only on commits and proposals.

enum DAVEOpcode: UInt8 {
    case prepareTransition = 21
    case executeTransition = 22
    case readyForTransition = 23
    case prepareEpoch = 24
    case externalSenderPackage = 25
    case keyPackage = 26
    case proposals = 27
    case commitWelcome = 28
    case announceCommitTransition = 29
    case welcome = 30
    case invalidCommitWelcome = 31

    /// What to call an opcode byte in the trace.
    ///
    /// Named rather than numbered, because the diagnosis is *which of the nine
    /// steps this was* and a reader should not have to hold the table in their
    /// head. Taken from the case itself so there is no second table to drift.
    static func name(_ opcode: UInt8) -> String {
        DAVEOpcode(rawValue: opcode).map(String.init(describing:)) ?? "unknown"
    }
}

/// A binary DAVE frame the server sent us.
enum DAVEInbound {
    case externalSender(ExternalSender)
    case proposals(DAVEProposals)
    case announceCommit(transitionID: UInt16, commit: MLSMessage)
    case welcome(transitionID: UInt16, welcome: Welcome)
    /// A DAVE frame that would not parse at all.
    ///
    /// Carried as an event rather than swallowed: a message this client cannot
    /// read is one whose effect on the group it cannot apply, so the only
    /// correct answer is to tell the gateway (opcode 31) and be re-added. A
    /// session that quietly ignored one would keep deriving keys from a group
    /// everybody else has already moved on from.
    case malformed

    /// The three bytes every server-to-client DAVE frame starts with.
    struct Header {
        var sequence: UInt16
        var opcode: UInt8
    }

    /// Reads the frame header, which is legible even when the payload is not.
    ///
    /// **Split from the payload deliberately, and for two reasons.** The
    /// sequence number is v8's, and it has to be acknowledged for a frame that
    /// *arrived* rather than only for one that parsed — a client that skips it
    /// on a message it could not read resumes by asking for everything since
    /// the last one it could. And the opcode is what says which of the nine
    /// steps this was, which is precisely the line worth having when the
    /// payload after it will not parse.
    static func header(of frame: [UInt8]) throws -> Header {
        guard frame.count >= 3 else {
            throw MLSError.malformed("a binary voice frame too short to hold an opcode")
        }
        return Header(sequence: UInt16(frame[0]) << 8 | UInt16(frame[1]), opcode: frame[2])
    }

    /// Parses the payload of a frame whose header has already been read.
    ///
    /// `nil` for an opcode the server should not be sending us — ignored
    /// rather than refused, because a frame we have no business receiving is
    /// not evidence that the group has diverged.
    static func parse(_ frame: [UInt8], header: Header) throws -> DAVEInbound? {
        guard let opcode = DAVEOpcode(rawValue: header.opcode) else { return nil }

        var reader = TLSReader(frame[3...])
        let message: DAVEInbound
        switch opcode {
        case .externalSenderPackage:
            message = .externalSender(try ExternalSender(from: &reader))
        case .proposals:
            message = .proposals(try DAVEProposals(from: &reader))
        case .announceCommitTransition:
            message = .announceCommit(
                transitionID: try reader.readUInt16(),
                commit: try MLSMessage(from: &reader)
            )
        case .welcome:
            message = .welcome(
                transitionID: try reader.readUInt16(),
                welcome: try Welcome(from: &reader)
            )
        default:
            // A binary opcode the server should not be sending us.
            return nil
        }
        try reader.finish()
        return message
    }
}

/// Opcode 27's payload: proposals to append, or references to withdraw.
enum DAVEProposals: TLSDecodable {
    case append([MLSMessage])
    case revoke([[UInt8]])

    init(from reader: inout TLSReader) throws {
        switch try reader.readByte() {
        case 0: self = .append(try reader.readVector(MLSMessage.self))
        case 1: self = .revoke(try reader.readVector(TLSOpaque.self).map(\.bytes))
        case let other: throw MLSError.malformed("proposals operation type \(other)")
        }
    }
}

/// A binary DAVE frame to send.
enum DAVEOutbound {
    case keyPackage(KeyPackage)
    case commitWelcome(commit: MLSMessage, welcome: Welcome?)

    var opcode: DAVEOpcode {
        switch self {
        case .keyPackage: .keyPackage
        case .commitWelcome: .commitWelcome
        }
    }

    /// **No sequence number.** Client-to-server binary frames carry the opcode
    /// and nothing before it.
    func encoded() throws -> [UInt8] {
        var writer = TLSWriter(reserving: 512)
        writer.write(opcode.rawValue)
        switch self {
        case .keyPackage(let keyPackage):
            try keyPackage.encode(into: &writer)
        case .commitWelcome(let commit, let welcome):
            try commit.encode(into: &writer)
            // The welcome is appended with no length or tag of its own: the
            // reader knows to expect one because the commit it just parsed
            // covers at least one add.
            if let welcome { try welcome.encode(into: &writer) }
        }
        return writer.bytes
    }
}
