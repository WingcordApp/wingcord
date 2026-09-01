import CryptoKit
import Foundation
import Testing

@testable import WingcordVoice

// MARK: - The tree, against trees other implementations built
//
// These are the vectors that decide whether this MLS is real. Everything above
// them — the key schedule, the welcome, the whole DAVE handshake — is built on
// deriving the same tree as everyone else, and a tree that is merely
// self-consistent produces a client that connects to nothing.

@Suite("MLS ratchet tree")
struct RatchetTreeTests {
    private func tree(from vector: [String: Any], key: String = "tree") throws -> RatchetTree {
        try RatchetTree(
            importing: try RatchetTreeExtension(unmarshalling: vector.hex(key)).nodes
        )
    }

    /// The truncate-and-repad rule from §12.4.3.3, both ways. Most of the
    /// published trees are shorter than their tree really is, so getting this
    /// wrong makes every other test here fail for the wrong reason.
    @Test("An imported tree pads back to a power of two and exports trimmed")
    func truncationRoundTrip() throws {
        for vector in try Vectors.load("tree-validation") {
            let serialised = try RatchetTreeExtension(unmarshalling: vector.hex("tree")).nodes
            let tree = try RatchetTree(importing: serialised)
            #expect(Int(tree.nodeCount) == vector.array("tree_hashes").count)
            #expect(tree.leafCount == TreeMath.fullLeafCount(tree.leafCount))
            #expect(tree.serialisedNodes == serialised)
        }
    }

    @Test("Tree hashes and resolutions match, node by node")
    func hashesAndResolutions() throws {
        for vector in try Vectors.load("tree-validation") {
            let tree = try tree(from: vector)
            let expectedHashes = vector.array("tree_hashes")
            let expectedResolutions = vector.array("resolutions")

            #expect(Int(tree.nodeCount) == expectedHashes.count)
            for node in 0..<tree.nodeCount {
                #expect(
                    tree.treeHash(of: node) == [UInt8](hexString: expectedHashes[Int(node)] as? String ?? ""),
                    "tree hash at node \(node)"
                )
                let expected = (expectedResolutions[Int(node)] as? [Any] ?? [])
                    .compactMap { ($0 as? NSNumber)?.uint32Value }
                #expect(tree.resolution(node) == expected, "resolution at node \(node)")
            }
        }
    }

    /// The two integrity properties a joiner checks on a tree it was handed.
    @Test("Every leaf signature and the whole parent hash chain verify")
    func integrity() throws {
        for vector in try Vectors.load("tree-validation") {
            let tree = try tree(from: vector)
            try tree.validateLeafSignatures(groupID: vector.hex("group_id"))
            #expect(tree.parentHashesValid())
        }
    }

    /// **The central test of the whole MLS layer.**
    ///
    /// For every published update path: merge it as each other member, and check
    /// three things independently — the tree hash afterwards, the path secret
    /// that member decrypts, and the commit secret that falls out. All three
    /// have to agree, and each one catches a different class of mistake: the
    /// hash catches structure, the path secret catches the HPKE labelling and
    /// the resolution order, and the commit secret catches the derivation.
    @Test("Update paths decrypt to the working group's path secrets")
    func updatePaths() throws {
        for vector in try Vectors.load("treekem") {
            let base = try tree(from: vector, key: "ratchet_tree")
            let groupID = vector.hex("group_id")
            let epoch = vector.uint64("epoch")
            let confirmed = vector.hex("confirmed_transcript_hash")

            for path in vector.array("update_paths") {
                guard let path = path as? [String: Any] else { continue }
                let sender = path.uint32("sender")
                let updatePath = try UpdatePath(unmarshalling: path.hex("update_path"))
                let secretsByLeaf = path.array("path_secrets")

                for privateLeaf in vector.array("leaves_private") {
                    guard let privateLeaf = privateLeaf as? [String: Any] else { continue }
                    let index = privateLeaf.uint32("index")
                    guard index != sender else { continue }

                    var tree = base
                    try tree.merge(from: sender, path: updatePath)
                    #expect(
                        tree.rootHash == path.hex("tree_hash_after"),
                        "tree hash after a merge from leaf \(sender)"
                    )

                    // The receiver's private state, as the vector describes it.
                    var privateState = TreeKEMPrivateState(
                        leafIndex: index,
                        leafPrivateKey: try P256.KeyAgreement.PrivateKey(
                            rawRepresentation: privateLeaf.hex("encryption_priv")
                        )
                    )
                    for entry in privateLeaf.array("path_secrets") {
                        guard let entry = entry as? [String: Any] else { continue }
                        privateState.seed(node: entry.uint32("node"), secret: entry.hex("path_secret"))
                    }

                    let context = try GroupContext(
                        groupID: groupID,
                        epoch: epoch,
                        treeHash: tree.rootHash,
                        confirmedTranscriptHash: confirmed,
                        extensions: []
                    ).marshalled()

                    try privateState.decapsulate(
                        updatePath, from: sender, tree: tree, groupContext: context
                    )

                    let overlap = TreeMath.commonAncestor(
                        TreeMath.nodeIndex(ofLeaf: sender), TreeMath.nodeIndex(ofLeaf: index)
                    )
                    if let expected = secretsByLeaf[Int(index)] as? String {
                        #expect(
                            privateState.pathSecrets[overlap] == [UInt8](hexString: expected),
                            "path secret leaf \(index) decrypts from leaf \(sender)"
                        )
                    }
                    #expect(
                        privateState.commitSecret == path.hex("commit_secret"),
                        "commit secret at leaf \(index) from leaf \(sender)"
                    )
                }
            }
        }
    }

    /// Growing and shrinking, which is what add and remove do to the array.
    @Test("A tree doubles to make room and halves when the right half empties")
    func growth() throws {
        let leaf = try makeLeaf(userID: 1)
        var tree = RatchetTree(leafNode: leaf)
        #expect(tree.leafCount == 1)
        #expect(tree.nodeCount == 1)

        let second = try tree.addLeaf(makeLeaf(userID: 2))
        #expect(second == 1)
        #expect(tree.leafCount == 2)
        #expect(tree.nodeCount == 3)

        let third = try tree.addLeaf(makeLeaf(userID: 3))
        #expect(third == 2)
        #expect(tree.leafCount == 4)
        #expect(tree.nodeCount == 7)

        // A hole is filled before the tree grows again.
        tree.blankPath(1)
        let fourth = try tree.addLeaf(makeLeaf(userID: 4))
        #expect(fourth == 1)
        #expect(tree.leafCount == 4)

        // And emptying the right half halves the tree.
        tree.blankPath(2)
        tree.truncate()
        #expect(tree.leafCount == 2)
        #expect(tree.nodeCount == 3)
    }

    private func makeLeaf(userID: UInt64) throws -> LeafNode {
        let signing = MLSCrypto.generateSignatureKey()
        let encryption = MLSCrypto.generateEncryptionKey()
        var leaf = LeafNode(
            encryptionKey: MLSCrypto.publicKeyBytes(encryption),
            signatureKey: MLSCrypto.publicKeyBytes(signing),
            credential: Credential(userID: userID),
            capabilities: .dave,
            source: .keyPackage(Lifetime()),
            extensions: [],
            signature: []
        )
        try leaf.sign(with: signing, groupID: [], leafIndex: 0)
        return leaf
    }
}
