import CryptoKit
import Foundation
import Testing

@testable import WingcordVoice

// MARK: - The primitives, against the working group's own numbers
//
// Every one of these is a construction that a reasonable person could implement
// three plausible ways. The vectors decide which one interoperates, and none of
// them are derived here from reading alone.

@Suite("MLS crypto primitives")
struct MLSCryptoTests {
    @Test("ExpandWithLabel, DeriveSecret and DeriveTreeSecret match RFC 9420")
    func keyDerivation() throws {
        for vector in try Vectors.load("crypto-basics") {
            let expand = vector.dict("expand_with_label")
            #expect(MLSCrypto.expandWithLabel(
                secret: expand.hex("secret"),
                label: expand.string("label"),
                context: expand.hex("context"),
                length: expand.int("length")
            ) == expand.hex("out"))

            let derive = vector.dict("derive_secret")
            #expect(MLSCrypto.deriveSecret(
                secret: derive.hex("secret"), label: derive.string("label")
            ) == derive.hex("out"))

            let tree = vector.dict("derive_tree_secret")
            #expect(MLSCrypto.deriveTreeSecret(
                secret: tree.hex("secret"),
                label: tree.string("label"),
                generation: tree.uint32("generation"),
                length: tree.int("length")
            ) == tree.hex("out"))
        }
    }

    @Test("RefHash matches, which is what makes a proposal reference agree")
    func refHash() throws {
        for vector in try Vectors.load("crypto-basics") {
            let reference = vector.dict("ref_hash")
            #expect(try MLSCrypto.refHash(
                label: reference.string("label"), value: reference.hex("value")
            ) == reference.hex("out"))
        }
    }

    /// The vector's signature cannot be compared byte for byte — ECDSA is
    /// randomised, so signing the same content twice gives two different valid
    /// signatures. Both directions are checked instead: theirs verifies under
    /// ours, and ours verifies under ours.
    @Test("SignWithLabel verifies the working group's signature")
    func signWithLabel() throws {
        for vector in try Vectors.load("crypto-basics") {
            let sign = vector.dict("sign_with_label")
            #expect(MLSCrypto.verify(
                publicKey: sign.hex("pub"),
                label: sign.string("label"),
                content: sign.hex("content"),
                signature: sign.hex("signature")
            ))

            let key = try P256.Signing.PrivateKey(rawRepresentation: sign.hex("priv"))
            let ours = try MLSCrypto.sign(
                privateKey: key, label: sign.string("label"), content: sign.hex("content")
            )
            #expect(MLSCrypto.verify(
                publicKey: sign.hex("pub"),
                label: sign.string("label"),
                content: sign.hex("content"),
                signature: ours
            ))

            // A signature must not verify against a different label: the label
            // is the whole reason MLS's signatures are not interchangeable
            // between structures that serialise alike.
            #expect(!MLSCrypto.verify(
                publicKey: sign.hex("pub"),
                label: "SomethingElse",
                content: sign.hex("content"),
                signature: sign.hex("signature")
            ))
        }
    }

    @Test("EncryptWithLabel opens the working group's ciphertext")
    func encryptWithLabel() throws {
        for vector in try Vectors.load("crypto-basics") {
            let encrypt = vector.dict("encrypt_with_label")
            let key = try P256.KeyAgreement.PrivateKey(rawRepresentation: encrypt.hex("priv"))
            let opened = try MLSCrypto.decrypt(
                with: key,
                label: encrypt.string("label"),
                context: encrypt.hex("context"),
                sealed: MLSCrypto.HPKESealed(
                    kemOutput: encrypt.hex("kem_output"),
                    ciphertext: encrypt.hex("ciphertext")
                )
            )
            #expect(opened == encrypt.hex("plaintext"))

            // And round-trips under our own sealing, to the same public key.
            let sealed = try MLSCrypto.encrypt(
                to: encrypt.hex("pub"),
                label: encrypt.string("label"),
                context: encrypt.hex("context"),
                plaintext: encrypt.hex("plaintext")
            )
            #expect(try MLSCrypto.decrypt(
                with: key,
                label: encrypt.string("label"),
                context: encrypt.hex("context"),
                sealed: sealed
            ) == encrypt.hex("plaintext"))
        }
    }

    /// `DeriveKeyPair` has no vector of its own, so it is pinned the way the
    /// protocol uses it: a derived key pair must be able to open what was
    /// sealed to its own public half, and must be deterministic in the input.
    @Test("DeriveKeyPair is deterministic and produces a usable key pair")
    func deriveKeyPair() throws {
        let ikm = MLSCrypto.deriveSecret(secret: [UInt8](repeating: 7, count: 32), label: "node")
        let first = try MLSCrypto.deriveKeyPair(ikm: ikm)
        let second = try MLSCrypto.deriveKeyPair(ikm: ikm)
        #expect(first.rawRepresentation == second.rawRepresentation)

        let other = try MLSCrypto.deriveKeyPair(ikm: MLSCrypto.deriveSecret(
            secret: [UInt8](repeating: 8, count: 32), label: "node"
        ))
        #expect(first.rawRepresentation != other.rawRepresentation)

        let sealed = try MLSCrypto.encrypt(
            to: MLSCrypto.publicKeyBytes(first),
            label: "UpdatePathNode",
            context: [1, 2, 3],
            plaintext: Array("hello".utf8)
        )
        #expect(try MLSCrypto.decrypt(
            with: first, label: "UpdatePathNode", context: [1, 2, 3], sealed: sealed
        ) == Array("hello".utf8))
    }
}

// MARK: - The presentation language

@Suite("TLS presentation language")
struct TLSCodecTests {
    /// The working group publishes a table of varint headers and the lengths
    /// they encode, including the ones that must be rejected. A permissive
    /// reader here is a signature check that passes on bytes the signer never
    /// produced.
    @Test("Variable-size vector length headers, including the invalid ones")
    func varintHeaders() throws {
        for vector in try Vectors.load("deserialization") {
            let header = vector.hex("vlbytes_header")
            let expected = vector["length"] as? NSNumber
            var reader = TLSReader(header)
            let decoded = try? reader.readVarint()

            if let expected {
                #expect(decoded == expected.intValue, "header \(header.hexString)")
                // And it re-encodes to exactly the same bytes: the encoding is
                // required to be minimal, so there is only one right answer.
                var writer = TLSWriter()
                try writer.writeVarint(expected.intValue)
                #expect(writer.bytes == header)
            } else {
                #expect(decoded == nil, "header \(header.hexString) should be rejected")
            }
        }
    }

    @Test("Integers are big-endian and round-trip")
    func integers() throws {
        var writer = TLSWriter()
        writer.write(UInt8(0x12))
        writer.write(UInt16(0x3456))
        writer.write(UInt32(0x789a_bcde))
        writer.write(UInt64(0x0102_0304_0506_0708))
        #expect(writer.bytes == [
            0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde,
            1, 2, 3, 4, 5, 6, 7, 8,
        ])

        var reader = TLSReader(writer.bytes)
        #expect(try reader.readByte() == 0x12)
        #expect(try reader.readUInt16() == 0x3456)
        #expect(try reader.readUInt32() == 0x789a_bcde)
        #expect(try reader.readUInt64() == 0x0102_0304_0506_0708)
        #expect(reader.isAtEnd)
    }

    @Test("A truncated buffer throws rather than reading past its end")
    func truncation() {
        var reader = TLSReader([0x40, 0x05])
        #expect(throws: (any Error).self) { _ = try reader.readOpaque() }
    }
}

// MARK: - The tree's arithmetic

@Suite("MLS tree math")
struct TreeMathTests {
    @Test("Every relationship in the working group's tree-math vectors")
    func relationships() throws {
        for vector in try Vectors.load("tree-math") {
            let leaves = vector.uint32("n_leaves")
            let nodes = vector.uint32("n_nodes")

            #expect(TreeMath.nodeWidth(leaves: leaves) == nodes)
            #expect(TreeMath.root(leaves: leaves) == vector.uint32("root"))

            // The vectors index by node, with null where the relationship is
            // undefined — a leaf has no children, the root has no parent.
            let left = vector.array("left")
            let right = vector.array("right")
            let parent = vector.array("parent")
            let sibling = vector.array("sibling")

            for node in 0..<Int(nodes) {
                let index = NodeIndex(node)
                if let expected = left[node] as? NSNumber {
                    #expect(TreeMath.left(index) == expected.uint32Value)
                } else {
                    #expect(TreeMath.level(index) == 0, "node \(node) should be a leaf")
                }
                if let expected = right[node] as? NSNumber {
                    #expect(TreeMath.right(index) == expected.uint32Value)
                }
                #expect(
                    TreeMath.parent(index, leaves: leaves) == (parent[node] as? NSNumber)?.uint32Value
                )
                #expect(
                    TreeMath.sibling(index, leaves: leaves)
                        == (sibling[node] as? NSNumber)?.uint32Value
                )
            }
        }
    }

    @Test("A direct path and its copath step together, leaf to root")
    func paths() {
        // Eight leaves: leaf 0 is node 0, and its direct path is 1, 3, 7 with
        // copath 2, 5, 11 — the siblings it must encrypt each path secret to.
        #expect(TreeMath.directPath(0, leaves: 8) == [1, 3, 7])
        #expect(TreeMath.copath(0, leaves: 8) == [2, 5, 11])
        #expect(TreeMath.directPath(0, leaves: 8).count
            == TreeMath.copath(0, leaves: 8).count)

        // A group of five lives in an eight-leaf tree with three blank leaves,
        // and `fullLeafCount` is the rounding that keeps every caller out of
        // the ragged case the bit arithmetic cannot express.
        #expect(TreeMath.fullLeafCount(5) == 8)
        #expect(TreeMath.fullLeafCount(8) == 8)
        #expect(TreeMath.fullLeafCount(1) == 1)
        #expect(TreeMath.directPath(8, leaves: TreeMath.fullLeafCount(5)) == [9, 11, 7])
        #expect(TreeMath.copath(8, leaves: TreeMath.fullLeafCount(5)) == [10, 13, 3])
    }

    @Test("Common ancestors are where an update path becomes decryptable")
    func commonAncestors() {
        #expect(TreeMath.commonAncestor(0, 2) == 1)
        #expect(TreeMath.commonAncestor(0, 4) == 3)
        #expect(TreeMath.commonAncestor(0, 8) == 7)
        #expect(TreeMath.commonAncestor(1, 0) == 1)
        #expect(TreeMath.commonAncestor(4, 6) == 5)
    }
}
