import CryptoKit
import Foundation

// MARK: - The ratchet tree
//
// The flat node array from `TreeMath`, with MLS's operations on it. Everything
// a group does to its membership happens here: a leaf is added, a leaf is
// blanked, and a member re-keys the path from its leaf to the root so that
// everyone still in the group can derive the new secrets and nobody who left
// can.
//
// Three ideas carry the whole file, and each one is a place a plausible
// implementation goes quietly wrong:
//
// - **Resolution.** The set of public keys that covers everything live beneath
//   a node. A blank node has no key of its own, so encrypting "to that subtree"
//   means encrypting to each key in its resolution — and a node's *unmerged
//   leaves* count, because a member added under a node was never told that
//   node's private key.
// - **The filtered direct path.** A node whose copath child resolves to nothing
//   needs no key: encrypting to it would be encrypting to its only live child
//   twice. Filtering is not an optimisation — the update path's length is
//   defined by it, and a client that filters differently produces a path the
//   receiver reads off by one.
// - **Parent hashes.** A chain from each member's leaf up to the root that says
//   "these node keys were set by a member, not chosen by whoever handed me this
//   tree". A joiner that skips checking them accepts a tree an attacker built.
//
// The tree hashes are recomputed wholesale rather than invalidated in place.
// That is a deliberate trade: it happens once per epoch change — a handful of
// SHA-256s over a group of a dozen people — and cache invalidation along a
// mutated path is exactly the kind of bookkeeping whose bugs show up as a
// commit that nobody else accepts.

struct RatchetTree {
    /// The flat array. Always `nodeWidth(leafCount)` long, with `nil` for a
    /// blank node.
    private(set) var nodes: [TreeNode?]
    /// Tree hashes by node, filled by `refreshHashes()`.
    private var hashes: [NodeIndex: [UInt8]] = [:]

    // MARK: Construction

    init(nodes: [TreeNode?]) {
        self.nodes = nodes
    }

    /// A group of one: a single occupied leaf.
    init(leafNode: LeafNode) {
        nodes = [.leaf(leafNode)]
    }

    /// Reads the tree out of a `ratchet_tree` extension.
    ///
    /// **The wire form is truncated and the in-memory form is not.** §12.4.3.3
    /// requires the sender to drop every blank after the last real node, and
    /// requires the receiver to check the last entry is non-blank and then pad
    /// back out to `2^(d+1) - 1`. Skipping the padding leaves a tree whose size
    /// is not a power of two, and every direct path computed from it is wrong —
    /// silently, because the arithmetic still returns numbers.
    init(importing serialised: [TreeNode?]) throws {
        guard let last = serialised.last else {
            throw MLSError.malformed("an empty ratchet tree")
        }
        guard last != nil else {
            throw MLSError.malformed("a ratchet tree ending in a blank node")
        }
        let leaves = TreeMath.fullLeafCount(
            TreeMath.leafCount(nodes: UInt32(serialised.count))
        )
        var nodes = serialised
        nodes.append(contentsOf: [TreeNode?](
            repeating: nil,
            count: Int(TreeMath.nodeWidth(leaves: leaves)) - serialised.count
        ))
        self.nodes = nodes
        refreshHashes()
    }

    /// The tree as a `ratchet_tree` extension body, with trailing blanks
    /// dropped as the sender is required to.
    var serialisedNodes: [TreeNode?] {
        var trimmed = nodes
        while trimmed.last == .some(nil) { trimmed.removeLast() }
        return trimmed
    }

    var leafCount: UInt32 { TreeMath.leafCount(nodes: UInt32(nodes.count)) }
    var nodeCount: UInt32 { UInt32(nodes.count) }

    // MARK: Reading

    subscript(node: NodeIndex) -> TreeNode? {
        guard node < nodeCount else { return nil }
        return nodes[Int(node)]
    }

    func isBlank(_ node: NodeIndex) -> Bool { self[node] == nil }

    func leafNode(at leaf: LeafIndex) -> LeafNode? {
        guard case .leaf(let node)? = self[TreeMath.nodeIndex(ofLeaf: leaf)] else { return nil }
        return node
    }

    func parentNode(at node: NodeIndex) -> ParentNode? {
        guard case .parent(let value)? = self[node] else { return nil }
        return value
    }

    /// The HPKE public key at a node, whichever kind of node it is.
    func encryptionKey(at node: NodeIndex) -> [UInt8]? {
        switch self[node] {
        case .leaf(let leaf): leaf.encryptionKey
        case .parent(let parent): parent.encryptionKey
        case nil: nil
        }
    }

    func parentHash(at node: NodeIndex) -> [UInt8]? {
        switch self[node] {
        case .leaf(let leaf):
            if case .commit(let hash) = leaf.source { return hash }
            return []
        case .parent(let parent): return parent.parentHash
        case nil: return nil
        }
    }

    /// Occupied leaves, left to right. This is the group's roster order and the
    /// order a `GroupInfo`'s signer index refers to.
    var occupiedLeaves: [LeafIndex] {
        var result: [LeafIndex] = []
        result.reserveCapacity(Int(leafCount))
        for leaf in 0..<leafCount where leafNode(at: leaf) != nil { result.append(leaf) }
        return result
    }

    // MARK: Resolution

    /// The ordered list of non-blank nodes covering every live descendant.
    ///
    /// Depth-first, left first. A non-blank parent contributes itself *and its
    /// unmerged leaves*, because those leaves do not hold its private key and
    /// a path secret encrypted only to the parent would never reach them.
    func resolution(_ node: NodeIndex) -> [NodeIndex] {
        switch self[node] {
        case .leaf:
            return [node]
        case .parent(let parent):
            var result = [node]
            result.append(contentsOf: parent.unmergedLeaves.map(TreeMath.nodeIndex(ofLeaf:)))
            return result
        case nil:
            guard TreeMath.level(node) > 0 else { return [] }
            return resolution(TreeMath.left(node)) + resolution(TreeMath.right(node))
        }
    }

    /// One entry per node on the sender's direct path that actually needs a
    /// key, paired with the resolution its path secret must be encrypted to.
    func filteredDirectPath(of leaf: LeafIndex) -> [(node: NodeIndex, resolution: [NodeIndex])] {
        filteredDirectPath(from: TreeMath.nodeIndex(ofLeaf: leaf))
    }

    func filteredDirectPath(
        from node: NodeIndex
    ) -> [(node: NodeIndex, resolution: [NodeIndex])] {
        let count = leafCount
        let direct = TreeMath.directPath(node, leaves: count)
        let copath = TreeMath.copath(node, leaves: count)
        var result: [(node: NodeIndex, resolution: [NodeIndex])] = []
        result.reserveCapacity(direct.count)
        for (parent, sibling) in zip(direct, copath) {
            let siblingResolution = resolution(sibling)
            guard !siblingResolution.isEmpty else { continue }
            result.append((parent, siblingResolution))
        }
        return result
    }

    // MARK: Membership

    /// Places a leaf in the leftmost blank slot, growing the tree if there is
    /// none, and records the new member as unmerged at every non-blank node
    /// above it.
    @discardableResult
    mutating func addLeaf(_ leaf: LeafNode) throws -> LeafIndex {
        guard !containsEncryptionKey(leaf.encryptionKey, ignoring: nil) else {
            throw MLSError.malformed("a key package reuses an encryption key already in the tree")
        }

        let index = allocateLeaf()
        nodes[Int(TreeMath.nodeIndex(ofLeaf: index))] = .leaf(leaf)

        for ancestor in TreeMath.directPath(
            TreeMath.nodeIndex(ofLeaf: index), leaves: leafCount
        ) {
            guard case .parent(var parent)? = self[ancestor] else { continue }
            // Kept sorted: the unmerged list is inside the parent hash, so its
            // order is part of what every member has to agree on.
            let insertion = parent.unmergedLeaves.firstIndex { $0 > index }
                ?? parent.unmergedLeaves.endIndex
            parent.unmergedLeaves.insert(index, at: insertion)
            nodes[Int(ancestor)] = .parent(parent)
        }
        return index
    }

    private mutating func allocateLeaf() -> LeafIndex {
        for leaf in 0..<leafCount where leafNode(at: leaf) == nil { return leaf }
        // Full: double the tree by appending a blank root and a blank subtree.
        nodes.append(contentsOf: [TreeNode?](repeating: nil, count: nodes.count + 1))
        return leafCount / 2
    }

    mutating func updateLeaf(_ index: LeafIndex, to leaf: LeafNode) {
        blankPath(index)
        nodes[Int(TreeMath.nodeIndex(ofLeaf: index))] = .leaf(leaf)
    }

    /// Blanks the leaf and everything above it — the operation that evicts a
    /// member's key material from the shared part of the tree.
    mutating func blankPath(_ index: LeafIndex) {
        let node = TreeMath.nodeIndex(ofLeaf: index)
        guard node < nodeCount else { return }
        nodes[Int(node)] = nil
        for ancestor in TreeMath.directPath(node, leaves: leafCount) {
            nodes[Int(ancestor)] = nil
        }
    }

    /// Halves the tree while its right half holds no members.
    ///
    /// Not cosmetic: the tree's size is in every direct path computation, so a
    /// tree left oversized after a departure produces update paths a correctly
    /// sized peer cannot read.
    mutating func truncate() {
        guard leafCount > 1 else { return }
        while leafCount > 1 {
            let half = leafCount / 2
            var occupied = false
            for leaf in half..<leafCount where leafNode(at: leaf) != nil {
                occupied = true
                break
            }
            guard !occupied else { break }
            nodes.removeLast(nodes.count - Int(TreeMath.nodeWidth(leaves: half)))
        }
    }

    private func containsEncryptionKey(_ key: [UInt8], ignoring leaf: LeafIndex?) -> Bool {
        for index in 0..<nodeCount {
            if let leaf, TreeMath.nodeIndex(ofLeaf: leaf) == index { continue }
            if encryptionKey(at: index) == key { return true }
        }
        return false
    }

    // MARK: Tree hashes

    /// Recomputes every node's tree hash. Call after any structural change and
    /// before reading `rootHash` or computing a parent hash.
    mutating func refreshHashes() {
        hashes.removeAll(keepingCapacity: true)
        hashes.reserveCapacity(Int(nodeCount))
        _ = computeHash(TreeMath.root(leaves: leafCount))
    }

    @discardableResult
    private mutating func computeHash(_ node: NodeIndex) -> [UInt8] {
        if let cached = hashes[node] { return cached }
        var writer = TLSWriter(reserving: 128)
        if TreeMath.level(node) == 0 {
            writer.write(UInt8(1))                       // NodeType.leaf
            writer.write(TreeMath.leafIndex(ofNode: node) ?? 0)
            // `try!`: the only throwing path in these writers is a vector past
            // 2^30 bytes, which a node in a live ratchet tree cannot reach.
            try! writer.writeOptional(self[node].flatMap {
                if case .leaf(let leaf) = $0 { return leaf } else { return nil }
            })
        } else {
            let left = computeHash(TreeMath.left(node))
            let right = computeHash(TreeMath.right(node))
            writer.write(UInt8(2))                       // NodeType.parent
            try! writer.writeOptional(parentNode(at: node))
            try! writer.writeOpaque(left)
            try! writer.writeOpaque(right)
        }
        let hash = MLSCrypto.hash(writer.bytes)
        hashes[node] = hash
        return hash
    }

    var rootHash: [UInt8] { hashes[TreeMath.root(leaves: leafCount)] ?? [] }

    func treeHash(of node: NodeIndex) -> [UInt8] { hashes[node] ?? [] }

    // MARK: Parent hashes

    /// `ParentHashInput` — a node's key, the parent hash above it, and the tree
    /// hash of the sibling subtree it is *not* re-keying.
    private static func parentHashInput(
        encryptionKey: [UInt8], parentHash: [UInt8], siblingTreeHash: [UInt8]
    ) -> [UInt8] {
        var writer = TLSWriter(reserving: 160)
        try! writer.writeOpaque(encryptionKey)
        try! writer.writeOpaque(parentHash)
        try! writer.writeOpaque(siblingTreeHash)
        return MLSCrypto.hash(writer.bytes)
    }

    /// The chain of parent hashes an update path implies, root first in
    /// computation order and leaf first in the array.
    ///
    /// Index 0 is the hash that goes into the sender's *leaf*; index `i` for
    /// `i > 0` is the hash stored at filtered-path entry `i - 1`.
    func parentHashes(
        from leaf: LeafIndex,
        filteredPath: [(node: NodeIndex, resolution: [NodeIndex])],
        pathNodes: [UpdatePathNode]
    ) throws -> [[UInt8]] {
        // An empty filtered path means a one-member tree: nobody to encrypt to,
        // and so no chain to build.
        guard !filteredPath.isEmpty else { return [] }
        guard filteredPath.count == pathNodes.count else {
            throw MLSError.malformed("update path length does not match the filtered direct path")
        }

        // The nodes that get a parent hash are the sender's leaf followed by
        // every filtered-path node except the topmost — the topmost is the root
        // of the chain and its own parent hash is empty.
        var chain: [NodeIndex] = [TreeMath.nodeIndex(ofLeaf: leaf)]
        chain.append(contentsOf: filteredPath.dropLast().map(\.node))

        var last = filteredPath[filteredPath.count - 1].node
        var hashes = [[UInt8]](repeating: [], count: chain.count)
        var carried: [UInt8] = []
        for index in stride(from: chain.count - 1, through: 0, by: -1) {
            let node = chain[index]
            let sibling = siblingWithin(last, of: node)
            carried = Self.parentHashInput(
                encryptionKey: pathNodes[index].encryptionKey,
                parentHash: carried,
                siblingTreeHash: treeHash(of: sibling)
            )
            hashes[index] = carried
            last = node
        }
        return hashes
    }

    /// The child of `ancestor` that `node` is *not* under.
    ///
    /// Not `TreeMath.sibling`: blank nodes are skipped on a filtered path, so
    /// the relevant copath child is a child of the next *filtered* node up,
    /// which may be several levels above `node`.
    private func siblingWithin(_ ancestor: NodeIndex, of node: NodeIndex) -> NodeIndex {
        let left = TreeMath.left(ancestor)
        return TreeMath.isDescendant(node, of: left) ? TreeMath.right(ancestor) : left
    }

    // MARK: Applying an update path

    /// Writes a sender's new leaf and path public keys into the tree, with the
    /// parent hashes the path implies.
    mutating func merge(from leaf: LeafIndex, path: UpdatePath) throws {
        updateLeaf(leaf, to: path.leafNode)
        refreshHashes()

        let filtered = filteredDirectPath(of: leaf)
        guard filtered.count == path.nodes.count else {
            throw MLSError.malformed("update path length does not match the filtered direct path")
        }
        let hashes = try parentHashes(
            from: leaf, filteredPath: filtered, pathNodes: path.nodes
        )
        for (index, entry) in filtered.enumerated() {
            // The topmost node's parent hash is empty; every other node carries
            // the hash of the one above it.
            let parentHash = index < filtered.count - 1 ? hashes[index + 1] : []
            nodes[Int(entry.node)] = .parent(ParentNode(
                encryptionKey: path.nodes[index].encryptionKey,
                parentHash: parentHash,
                unmergedLeaves: []
            ))
        }
        refreshHashes()
    }

    // MARK: Validation

    /// Whether every non-blank parent node was set by a member of the group.
    ///
    /// **This is the check a joiner cannot skip.** The ratchet tree arrives
    /// inside a welcome from somebody the joiner has no reason to trust yet; the
    /// parent hash chain is what ties each interior key back to a leaf that
    /// signed for it. Without it, a malicious committer can hand a new member a
    /// tree whose interior keys it chose, and read everything that member sends.
    func parentHashesValid() -> Bool {
        var cache: [NodeIndex: (excluded: Int, hash: [UInt8])] = [:]
        let width = nodeCount
        let height = TreeMath.level(TreeMath.root(leaves: leafCount))
        guard height > 0 else { return true }

        for level in 1...height {
            let stride = UInt32(2) << level
            var node = (stride >> 1) - 1
            while node < width {
                defer { node += stride }
                guard parentNode(at: node) != nil else { continue }
                let left = TreeMath.left(node)
                let right = TreeMath.right(node)
                // One of the two children must carry the parent hash this node
                // implies — whichever side last re-keyed through it.
                let viaLeft = originalParentHash(&cache, parent: node, sibling: right)
                let viaRight = originalParentHash(&cache, parent: node, sibling: left)
                if !hasParentHash(child: left, equalTo: viaLeft),
                   !hasParentHash(child: right, equalTo: viaRight) {
                    return false
                }
            }
        }
        return true
    }

    private func hasParentHash(child: NodeIndex, equalTo target: [UInt8]) -> Bool {
        resolution(child).contains { parentHash(at: $0) == target }
    }

    private func originalParentHash(
        _ cache: inout [NodeIndex: (excluded: Int, hash: [UInt8])],
        parent: NodeIndex,
        sibling: NodeIndex
    ) -> [UInt8] {
        guard let node = parentNode(at: parent) else { return [] }
        let siblingHash = originalTreeHash(
            &cache, node: sibling, excluding: node.unmergedLeaves
        )
        return Self.parentHashInput(
            encryptionKey: node.encryptionKey,
            parentHash: node.parentHash,
            siblingTreeHash: siblingHash
        )
    }

    /// The tree hash of a subtree as it was *before* a set of leaves were added
    /// under it — §7.9's "original sibling tree hash".
    ///
    /// A parent's unmerged leaves joined after it was last set, so they were not
    /// part of what its parent hash committed to. Hashing the subtree with them
    /// blanked is what makes the hash stable across additions, which is the
    /// property that lets the chain survive people joining.
    private func originalTreeHash(
        _ cache: inout [NodeIndex: (excluded: Int, hash: [UInt8])],
        node: NodeIndex,
        excluding parentExcept: [LeafIndex]
    ) -> [UInt8] {
        let except = parentExcept.filter {
            TreeMath.isDescendant(TreeMath.nodeIndex(ofLeaf: $0), of: node)
        }
        guard !except.isEmpty else { return treeHash(of: node) }
        if let cached = cache[node], cached.excluded == except.count { return cached.hash }

        var writer = TLSWriter(reserving: 128)
        if TreeMath.level(node) == 0 {
            // An excluded leaf hashes as a blank one.
            writer.write(UInt8(1))
            writer.write(TreeMath.leafIndex(ofNode: node) ?? 0)
            try! writer.writeOptional(Optional<LeafNode>.none)
        } else {
            let left = originalTreeHash(&cache, node: TreeMath.left(node), excluding: except)
            let right = originalTreeHash(&cache, node: TreeMath.right(node), excluding: except)
            var scoped = parentNode(at: node)
            scoped?.unmergedLeaves.removeAll { except.contains($0) }
            writer.write(UInt8(2))
            try! writer.writeOptional(scoped)
            try! writer.writeOpaque(left)
            try! writer.writeOpaque(right)
        }
        let hash = MLSCrypto.hash(writer.bytes)
        cache[node] = (except.count, hash)
        return hash
    }

    /// Every leaf node in the tree verifies under its own signature key, at the
    /// index it actually sits at.
    func validateLeafSignatures(groupID: [UInt8]) throws {
        for leaf in occupiedLeaves {
            guard let node = leafNode(at: leaf) else { continue }
            try node.verifySignature(groupID: groupID, leafIndex: leaf)
        }
    }
}

// MARK: - The private half of the tree

/// The path secrets and leaf key a member holds for its own view of the tree.
///
/// Separate from `RatchetTree` because the two have different lifetimes and
/// very different exposure: the public tree is shipped to joiners inside a
/// welcome, and this must never leave the process.
struct TreeKEMPrivateState {
    let leafIndex: LeafIndex
    /// Path secrets by node. The leaf's own entry is the seed the rest derive
    /// from when we are the committer.
    private(set) var pathSecrets: [NodeIndex: [UInt8]] = [:]
    /// The leaf's HPKE key when it was generated rather than derived.
    private(set) var leafPrivateKey: P256.KeyAgreement.PrivateKey?
    /// `DeriveSecret(topmost path secret, "path")` — the commit secret that
    /// feeds the epoch's key schedule.
    private(set) var commitSecret: [UInt8] = []

    init(leafIndex: LeafIndex, leafPrivateKey: P256.KeyAgreement.PrivateKey?) {
        self.leafIndex = leafIndex
        self.leafPrivateKey = leafPrivateKey
    }

    func hasKey(for node: NodeIndex) -> Bool {
        if node == TreeMath.nodeIndex(ofLeaf: leafIndex), leafPrivateKey != nil { return true }
        return pathSecrets[node] != nil
    }

    /// The HPKE private key for a node, derived from its path secret.
    ///
    /// `node_secret = DeriveSecret(path_secret, "node")` then
    /// `DeriveKeyPair(node_secret)` — the two-step derivation exists so that no
    /// single secret is fed to two different algorithms.
    func privateKey(for node: NodeIndex) throws -> P256.KeyAgreement.PrivateKey? {
        if node == TreeMath.nodeIndex(ofLeaf: leafIndex), let key = leafPrivateKey { return key }
        guard let secret = pathSecrets[node] else { return nil }
        return try MLSCrypto.deriveKeyPair(
            ikm: MLSCrypto.deriveSecret(secret: secret, label: "node")
        )
    }

    /// Seeds a path secret at `start` and derives it up the tree's **filtered**
    /// direct path — the form used when we generate a path ourselves, and when
    /// we decrypt one addressed to us.
    mutating func implant(_ tree: RatchetTree, at start: NodeIndex, secret: [UInt8]) {
        var current = secret
        pathSecrets[start] = current
        for entry in tree.filteredDirectPath(from: start) {
            current = MLSCrypto.deriveSecret(secret: current, label: "path")
            pathSecrets[entry.node] = current
        }
        commitSecret = MLSCrypto.deriveSecret(secret: current, label: "path")
    }

    /// The same walk, but following the *unfiltered* direct path and skipping
    /// blanks.
    ///
    /// A member joining from a welcome cannot always reproduce the committer's
    /// resolutions, but it can see which nodes ended up with keys — and after a
    /// commit those are exactly the filtered ones, because a commit blanks the
    /// whole direct path before assigning to the filtered subset.
    mutating func implantMatching(_ tree: RatchetTree, at start: NodeIndex, secret: [UInt8]) {
        var current = secret
        pathSecrets[start] = current
        for node in TreeMath.directPath(start, leaves: tree.leafCount)
        where !tree.isBlank(node) {
            current = MLSCrypto.deriveSecret(secret: current, label: "path")
            pathSecrets[node] = current
        }
        commitSecret = MLSCrypto.deriveSecret(secret: current, label: "path")
    }

    /// The path secret the committer should hand a joiner: the one at the
    /// lowest node the two leaves share.
    func sharedPathSecret(with leaf: LeafIndex) -> [UInt8]? {
        let ancestor = TreeMath.commonAncestor(
            TreeMath.nodeIndex(ofLeaf: leafIndex), TreeMath.nodeIndex(ofLeaf: leaf)
        )
        return pathSecrets[ancestor]
    }

    mutating func setCommitSecretToZero() {
        commitSecret = [UInt8](repeating: 0, count: MLSCrypto.hashLength)
    }

    mutating func truncate(to leafCount: UInt32) {
        let ceiling = TreeMath.nodeWidth(leaves: leafCount)
        pathSecrets = pathSecrets.filter { $0.key < ceiling }
    }

    /// Places a path secret at a node without deriving anything from it. For
    /// restoring a saved view of the tree, and for the working group's vectors.
    mutating func seed(node: NodeIndex, secret: [UInt8]) {
        pathSecrets[node] = secret
    }

    /// Opens the one ciphertext in an incoming update path that was sealed for
    /// us, and derives the rest of the path from it.
    ///
    /// **Call this after the path has been merged into `tree`.** The group
    /// context that was used as HPKE `info` contains the tree hash *after* the
    /// merge, so a decryption attempted against the old tree fails with no
    /// indication of why.
    ///
    /// `joiners` are the leaves this same commit adds. They are cut out of the
    /// resolution before the ciphertexts are counted off against it, because
    /// the sender did the same: a new member gets its path secret in the
    /// welcome, not in the update path. Skipping that step shifts every index
    /// after the joiner by one, and the failure is a decryption error at a
    /// completely unrelated node.
    mutating func decapsulate(
        _ path: UpdatePath,
        from sender: LeafIndex,
        tree: RatchetTree,
        groupContext: [UInt8],
        excluding joiners: [LeafIndex] = []
    ) throws {
        let ourNode = TreeMath.nodeIndex(ofLeaf: leafIndex)
        let filtered = tree.filteredDirectPath(of: sender)
        guard filtered.count == path.nodes.count else {
            throw MLSError.malformed("update path length does not match the filtered direct path")
        }

        // The step where the sender's path first passes above us is the one
        // carrying a secret we are entitled to.
        guard let step = filtered.firstIndex(where: {
            TreeMath.isDescendant(ourNode, of: $0.node)
        }) else {
            throw MLSError.malformed("update path never passes above this leaf")
        }

        var resolution = filtered[step].resolution
        for joiner in joiners {
            let node = TreeMath.nodeIndex(ofLeaf: joiner)
            if let index = resolution.firstIndex(of: node) { resolution.remove(at: index) }
        }
        guard resolution.count == path.nodes[step].encryptedPathSecret.count else {
            throw MLSError.malformed("update path node has the wrong number of ciphertexts")
        }

        // Whichever resolution entry we hold a key for. Choosing by key
        // possession rather than by position handles the case where we sit
        // unmerged beneath a node we were never given the private half of —
        // there the sender encrypted to the node *and* to our leaf, and only
        // the second one opens.
        guard let slot = resolution.firstIndex(where: { hasKey(for: $0) }),
              let key = try privateKey(for: resolution[slot])
        else { throw MLSError.noPrivateKey }

        let secret = try MLSCrypto.decrypt(
            with: key,
            label: "UpdatePathNode",
            context: groupContext,
            sealed: path.nodes[step].encryptedPathSecret[slot].sealed
        )
        implant(tree, at: filtered[step].node, secret: secret)
    }
}

// MARK: - Producing an update path

extension RatchetTree {
    /// Re-keys `leaf`'s direct path and writes the result into the tree,
    /// returning the private state and the still-unencrypted path.
    ///
    /// Split from `encapsulate` because the two need the tree in different
    /// states: the new public keys have to be in place before the group context
    /// can be computed, and the group context is what the encryptions bind to.
    mutating func update(
        from leaf: LeafIndex,
        leafSecret: [UInt8],
        groupID: [UInt8],
        signatureKey: P256.Signing.PrivateKey
    ) throws -> (state: TreeKEMPrivateState, path: UpdatePath) {
        guard let existing = leafNode(at: leaf) else { throw MLSError.blankNode }

        var state = TreeKEMPrivateState(leafIndex: leaf, leafPrivateKey: nil)
        state.implant(self, at: TreeMath.nodeIndex(ofLeaf: leaf), secret: leafSecret)

        let filtered = filteredDirectPath(of: leaf)
        var pathNodes: [UpdatePathNode] = []
        pathNodes.reserveCapacity(filtered.count)
        for entry in filtered {
            guard let key = try state.privateKey(for: entry.node) else {
                throw MLSError.noPrivateKey
            }
            pathNodes.append(UpdatePathNode(
                encryptionKey: MLSCrypto.publicKeyBytes(key), encryptedPathSecret: []
            ))
        }

        let hashes = try parentHashes(
            from: leaf, filteredPath: filtered, pathNodes: pathNodes
        )
        guard let leafKey = try state.privateKey(for: TreeMath.nodeIndex(ofLeaf: leaf)) else {
            throw MLSError.noPrivateKey
        }

        var newLeaf = existing
        newLeaf.encryptionKey = MLSCrypto.publicKeyBytes(leafKey)
        newLeaf.source = .commit(parentHash: hashes.first ?? [])
        try newLeaf.sign(with: signatureKey, groupID: groupID, leafIndex: leaf)

        let path = UpdatePath(leafNode: newLeaf, nodes: pathNodes)
        try merge(from: leaf, path: path)
        return (state, path)
    }

    /// Seals each path secret to the resolution of the copath child beside it.
    func encapsulate(
        _ state: TreeKEMPrivateState,
        groupContext: [UInt8],
        excluding joiners: [LeafIndex] = []
    ) throws -> UpdatePath {
        guard let leaf = leafNode(at: state.leafIndex) else { throw MLSError.blankNode }
        let filtered = filteredDirectPath(of: state.leafIndex)

        var pathNodes: [UpdatePathNode] = []
        pathNodes.reserveCapacity(filtered.count)
        for entry in filtered {
            guard let secret = state.pathSecrets[entry.node],
                  let key = try state.privateKey(for: entry.node)
            else { throw MLSError.noPrivateKey }

            var resolution = entry.resolution
            for joiner in joiners {
                let node = TreeMath.nodeIndex(ofLeaf: joiner)
                if let index = resolution.firstIndex(of: node) { resolution.remove(at: index) }
            }

            var ciphertexts: [HPKECiphertext] = []
            ciphertexts.reserveCapacity(resolution.count)
            for node in resolution {
                guard let publicKey = encryptionKey(at: node) else { throw MLSError.blankNode }
                ciphertexts.append(HPKECiphertext(try MLSCrypto.encrypt(
                    to: publicKey,
                    label: "UpdatePathNode",
                    context: groupContext,
                    plaintext: secret
                )))
            }
            pathNodes.append(UpdatePathNode(
                encryptionKey: MLSCrypto.publicKeyBytes(key), encryptedPathSecret: ciphertexts
            ))
        }
        return UpdatePath(leafNode: leaf, nodes: pathNodes)
    }
}
