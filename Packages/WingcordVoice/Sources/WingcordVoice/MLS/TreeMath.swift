import Foundation

// MARK: - The ratchet tree's arithmetic
//
// MLS's ratchet tree is a *complete balanced* binary tree, which means it needs
// no pointers at all: RFC 9420 Appendix C lays it flat in an array where leaf
// *n* sits at index `2n` and every odd index is an interior node.
//
//                           X
//                 .---------+---------.
//                X                     X
//            .---+---.             .---+---.
//           X         X           X         X
//          / \       / \         / \       / \
//         X   X     X   X       X   X     X   X
//   Node: 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14
//   Leaf: 0   1   2   3   4    5     6     7
//
// Every relationship is then bit arithmetic on the index, which is why this
// whole file is integers and no allocation. `parent` and `sibling` depend on
// the tree's *size* as well as the index — near the right edge the tree is
// ragged and a node's parent is not where the bit pattern alone would put it —
// so the size is a parameter and never an assumption.
//
// **The leaf count is always a power of two, and every function here assumes
// it.** A group of five is an eight-leaf tree with three blank leaves, because
// §7.7 grows the tree by doubling and shrinks it by halving — there is no such
// thing as a nine-node ratchet tree. That is not a detail to be discovered
// later: `parent(8, leaves: 5)` returns node 9, which is off the end of a
// nine-node array, and a caller that passed a raw member count would walk into
// it. `fullLeafCount` is the rounding-up every caller goes through, and the
// published `tree-math.json` vectors are powers of two for exactly this reason.
//
// The names are RFC 9420's own, and `TreeMathTests` pins every function against
// those vectors.

/// An index into the flat node array. Even values are leaves.
typealias NodeIndex = UInt32
/// An index into the leaves alone. Leaf *n* is node `2n`.
typealias LeafIndex = UInt32

enum TreeMath {
    /// ⌊log₂ x⌋, and 0 for x = 0 — RFC 9420's `log2`, which is deliberately
    /// not the mathematical one at the origin.
    static func log2(_ value: UInt32) -> UInt32 {
        guard value > 0 else { return 0 }
        return 31 - UInt32(value.leadingZeroBitCount)
    }

    /// How far above the leaves a node sits. Leaves are 0.
    ///
    /// The trailing-ones count *is* the level: leaves are even (no trailing
    /// one), their parents end in `01`, the next level in `011`, and so on.
    static func level(_ node: NodeIndex) -> UInt32 {
        UInt32((~node).trailingZeroBitCount)
    }

    /// The smallest power of two that holds `members` leaves — the actual width
    /// of the tree a group of that size lives in.
    static func fullLeafCount(_ members: UInt32) -> UInt32 {
        var width: UInt32 = 1
        while width < members { width <<= 1 }
        return width
    }

    /// The size of the flat array for a tree with `leaves` leaves.
    static func nodeWidth(leaves: UInt32) -> UInt32 {
        leaves == 0 ? 0 : 2 * (leaves - 1) + 1
    }

    /// The number of leaves a `nodes`-long array holds.
    static func leafCount(nodes: UInt32) -> UInt32 {
        nodes == 0 ? 0 : (nodes - 1) / 2 + 1
    }

    static func root(leaves: UInt32) -> NodeIndex {
        let width = nodeWidth(leaves: leaves)
        return (1 << log2(width)) - 1
    }

    /// The left child. Undefined for a leaf, and the caller is expected to know
    /// it is not asking about one.
    static func left(_ node: NodeIndex) -> NodeIndex {
        let k = level(node)
        precondition(k > 0, "a leaf has no children")
        return node ^ (1 << (k - 1))
    }

    static func right(_ node: NodeIndex) -> NodeIndex {
        let k = level(node)
        precondition(k > 0, "a leaf has no children")
        return node ^ (3 << (k - 1))
    }

    /// The parent, or `nil` at the root.
    static func parent(_ node: NodeIndex, leaves: UInt32) -> NodeIndex? {
        guard node != root(leaves: leaves) else { return nil }
        let k = level(node)
        let bit = (node >> (k + 1)) & 1
        return (node | (1 << k)) ^ (bit << (k + 1))
    }

    /// The other child of this node's parent, or `nil` at the root.
    static func sibling(_ node: NodeIndex, leaves: UInt32) -> NodeIndex? {
        guard let parent = parent(node, leaves: leaves) else { return nil }
        return node < parent ? right(parent) : left(parent)
    }

    /// Every node from this one's parent up to and including the root, in that
    /// order. Empty at the root.
    static func directPath(_ node: NodeIndex, leaves: UInt32) -> [NodeIndex] {
        let r = root(leaves: leaves)
        guard node != r else { return [] }
        var path: [NodeIndex] = []
        path.reserveCapacity(Int(log2(nodeWidth(leaves: leaves))) + 1)
        var current = node
        while current != r, let next = parent(current, leaves: leaves) {
            current = next
            path.append(current)
        }
        return path
    }

    /// The siblings of the node and of every step of its direct path below the
    /// root — one copath entry per direct-path entry, in the same order.
    ///
    /// This is what an UpdatePath encrypts to: each new path secret goes to the
    /// resolution of the copath node at the same index.
    static func copath(_ node: NodeIndex, leaves: UInt32) -> [NodeIndex] {
        let r = root(leaves: leaves)
        guard node != r else { return [] }
        var path = directPath(node, leaves: leaves)
        path.insert(node, at: 0)
        path.removeLast()
        return path.compactMap { sibling($0, leaves: leaves) }
    }

    /// The lowest node on both direct paths.
    ///
    /// Used to find where an incoming UpdatePath's secret becomes decryptable
    /// by us: the sender encrypted one secret per copath node, and the one we
    /// can open is at the ancestor we share.
    static func commonAncestor(_ x: NodeIndex, _ y: NodeIndex) -> NodeIndex {
        // Where one is already an ancestor of the other, it is the answer.
        let lx = level(x) + 1
        let ly = level(y) + 1
        if lx <= ly, x >> ly == y >> ly { return y }
        if ly <= lx, x >> lx == y >> lx { return x }

        // Otherwise, walk both up to the level where their paths merge.
        var xn = x
        var yn = y
        var k: UInt32 = 0
        while xn != yn {
            xn >>= 1
            yn >>= 1
            k += 1
        }
        return (xn << k) + (1 << (k - 1)) - 1
    }

    /// Whether `ancestor` is on the direct path of `node` (or is the node).
    static func isDescendant(_ node: NodeIndex, of ancestor: NodeIndex) -> Bool {
        let k = level(ancestor) + 1
        return node >> k == ancestor >> k
    }

    static func nodeIndex(ofLeaf leaf: LeafIndex) -> NodeIndex { leaf * 2 }

    static func leafIndex(ofNode node: NodeIndex) -> LeafIndex? {
        node.isMultiple(of: 2) ? node / 2 : nil
    }
}
