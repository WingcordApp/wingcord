import Foundation
import Testing

@testable import WingcordVoice

// MARK: - Round-tripping the working group's own messages
//
// Every structure here is decoded from bytes another implementation produced
// and then re-encoded, and the two byte strings must be identical. That is a
// stronger check than "it parses": MLS signs its own serialisations, so a
// decoder that is permissive where the encoder is not produces a message that
// verifies locally and nowhere else.

@Suite("MLS message serialisation")
struct MLSMessageTests {
    /// Decode, re-encode, compare. Named so a failure says which structure.
    private func roundTrip<T: TLSCodable & Equatable>(
        _ type: T.Type, _ bytes: [UInt8], _ what: String
    ) throws {
        let value = try T(unmarshalling: bytes)
        let reencoded = try value.marshalled()
        #expect(reencoded == bytes, "\(what) did not re-encode to the same bytes")
        // And decoding the re-encoding gives an equal value, which catches a
        // field that round-trips bytes while landing in the wrong property.
        #expect(try T(unmarshalling: reencoded) == value, "\(what) is not stable")
    }

    @Test("Key packages, welcomes and group infos re-encode byte for byte")
    func envelopes() throws {
        for vector in try Vectors.load("messages") {
            try roundTrip(MLSMessage.self, vector.hex("mls_key_package"), "key package")
            try roundTrip(MLSMessage.self, vector.hex("mls_welcome"), "welcome")
            try roundTrip(MLSMessage.self, vector.hex("mls_group_info"), "group info")
        }
    }

    /// The vectors store each proposal's *body* — the `select` arm — without
    /// the `uint16 proposal_type` that discriminates it, so the tag is put back
    /// on here to make a whole `Proposal`.
    private func tagged(_ type: UInt16, _ body: [UInt8]) -> [UInt8] {
        [UInt8(type >> 8), UInt8(truncatingIfNeeded: type)] + body
    }

    @Test("Add, update and remove proposals round-trip once they are tagged")
    func proposals() throws {
        for vector in try Vectors.load("messages") {
            try roundTrip(Proposal.self, tagged(1, vector.hex("add_proposal")), "add proposal")
            try roundTrip(
                Proposal.self, tagged(2, vector.hex("update_proposal")), "update proposal"
            )
            try roundTrip(
                Proposal.self, tagged(3, vector.hex("remove_proposal")), "remove proposal"
            )
        }
    }

    @Test("Public messages carrying a proposal and a commit")
    func publicMessages() throws {
        for vector in try Vectors.load("messages") {
            try roundTrip(
                MLSMessage.self, vector.hex("public_message_proposal"), "public proposal"
            )
            try roundTrip(MLSMessage.self, vector.hex("public_message_commit"), "public commit")
        }
    }

    @Test("The ratchet tree, blanks and all")
    func ratchetTree() throws {
        for vector in try Vectors.load("messages") {
            try roundTrip(RatchetTreeExtension.self, vector.hex("ratchet_tree"), "ratchet tree")
        }
    }

    @Test("Group secrets, including the optional path secret")
    func groupSecrets() throws {
        for vector in try Vectors.load("messages") {
            try roundTrip(GroupSecrets.self, vector.hex("group_secrets"), "group secrets")
        }
    }

    /// A proposal type DAVE must refuse is refused at the parse, not later.
    ///
    /// The bodies come from the vectors and the tags are the ones IANA assigns,
    /// so these are the real messages a misbehaving delivery service could send
    /// — not synthetic bytes chosen to fail.
    @Test("A proposal type the protocol forbids does not decode")
    func forbiddenProposals() throws {
        let forbidden: [(UInt16, String)] = [
            (4, "pre_shared_key_proposal"),
            (5, "re_init_proposal"),
            (6, "external_init_proposal"),
            (7, "group_context_extensions_proposal"),
        ]
        for vector in try Vectors.load("messages") {
            for (type, key) in forbidden {
                #expect(throws: (any Error).self) {
                    _ = try Proposal(unmarshalling: tagged(type, vector.hex(key)))
                }
            }
        }
    }

    /// A DAVE credential is a big-endian snowflake, and the roster is built by
    /// reading it back out. Both directions are pinned here because a client
    /// that agrees with itself on the wrong endianness derives per-sender keys
    /// nobody else derives — and the failure looks like silence, not an error.
    @Test("A basic credential round-trips a Discord user ID big-endian")
    func credentialIdentity() throws {
        let id: UInt64 = 104_694_319_309_049_672
        let credential = Credential(userID: id)
        #expect(credential.identity == [0x01, 0x73, 0xF2, 0xED, 0xC0, 0x40, 0x10, 0x00])
        #expect(credential.userID == id)
        #expect(try Credential(unmarshalling: try credential.marshalled()) == credential)
    }
}
