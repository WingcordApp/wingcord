import CryptoKit
import Foundation

// MARK: - The objects on the wire
//
// Every structure MLS puts on a socket, in RFC 9420's field order and no other.
// The order *is* the format — there are no tags and no names in the encoding —
// so a field moved is a message that parses into plausible nonsense and then
// fails a signature check somewhere far away from the mistake.
//
// Two things are deliberately narrower than the RFC:
//
// - **Only the `basic` credential exists here.** DAVE's MLS parameters allow
//   exactly one credential type, and its identity is a big-endian Discord
//   snowflake. Carrying an X.509 branch would be a code path no Discord call
//   can reach and nothing would ever test.
// - **Only `add` and `update` and `remove` proposals decode.** The voice
//   gateway is the only external sender and it sends add and remove; a commit's
//   path carries an update-shaped leaf. Anything else is refused at the parse
//   rather than deeper in, which is what the protocol asks for: "Clients must
//   reject a proposal if it is not one of the allowed proposal types."

// MARK: Credential

/// `struct { uint16 credential_type = 1; opaque identity<V>; }`
///
/// The identity is the member's Discord user ID as a big-endian `uint64`, which
/// is what makes a roster out of a ratchet tree.
struct Credential: TLSCodable, Equatable {
    static let basicType: UInt16 = 1

    var identity: [UInt8]

    init(identity: [UInt8]) { self.identity = identity }

    init(userID: UInt64) {
        var writer = TLSWriter(reserving: 8)
        writer.write(userID)
        identity = writer.bytes
    }

    /// The user ID this credential names, or `nil` if it is not eight bytes.
    var userID: UInt64? {
        guard identity.count == 8 else { return nil }
        return identity.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }

    init(from reader: inout TLSReader) throws {
        let type = try reader.readUInt16()
        guard type == Self.basicType else { throw MLSError.unsupportedCredential(type) }
        identity = try reader.readOpaque()
    }

    func encode(into writer: inout TLSWriter) throws {
        writer.write(Self.basicType)
        try writer.writeOpaque(identity)
    }
}

// MARK: Capabilities and lifetime

/// What a client says it supports. DAVE pins every field, so two clients in the
/// same call produce byte-identical capabilities — which matters, because this
/// is inside the signed leaf node.
struct Capabilities: TLSCodable, Equatable {
    var versions: [UInt16]
    var cipherSuites: [UInt16]
    var extensions: [UInt16]
    var proposals: [UInt16]
    var credentials: [UInt16]

    /// The one shape DAVE uses: MLS 1.0, ciphersuite 2, basic credentials, and
    /// nothing non-default. The empty extension and proposal lists are required
    /// rather than lazy — §7.2 says default types "MUST NOT be listed".
    static let dave = Capabilities(
        versions: [MLSCrypto.protocolVersion],
        cipherSuites: [MLSCrypto.cipherSuiteID],
        extensions: [],
        proposals: [],
        credentials: [Credential.basicType]
    )

    init(
        versions: [UInt16], cipherSuites: [UInt16], extensions: [UInt16],
        proposals: [UInt16], credentials: [UInt16]
    ) {
        self.versions = versions
        self.cipherSuites = cipherSuites
        self.extensions = extensions
        self.proposals = proposals
        self.credentials = credentials
    }

    init(from reader: inout TLSReader) throws {
        versions = try reader.readVector(UInt16.self)
        cipherSuites = try reader.readVector(UInt16.self)
        extensions = try reader.readVector(UInt16.self)
        proposals = try reader.readVector(UInt16.self)
        credentials = try reader.readVector(UInt16.self)
    }

    func encode(into writer: inout TLSWriter) throws {
        try writer.writeVector(versions)
        try writer.writeVector(cipherSuites)
        try writer.writeVector(extensions)
        try writer.writeVector(proposals)
        try writer.writeVector(credentials)
    }
}

/// **The voice gateway requires the maximal span and validates it.** A key
/// package with a real expiry is refused, so this is not a default that could
/// drift — it is the only value the server accepts.
struct Lifetime: TLSCodable, Equatable {
    var notBefore: UInt64 = 0
    var notAfter: UInt64 = .max

    init(notBefore: UInt64 = 0, notAfter: UInt64 = .max) {
        self.notBefore = notBefore
        self.notAfter = notAfter
    }

    init(from reader: inout TLSReader) throws {
        notBefore = try reader.readUInt64()
        notAfter = try reader.readUInt64()
    }

    func encode(into writer: inout TLSWriter) throws {
        writer.write(notBefore)
        writer.write(notAfter)
    }
}

// MARK: Extensions

struct MLSExtension: TLSCodable, Equatable {
    enum Kind: UInt16 {
        case applicationID = 1
        case ratchetTree = 2
        case requiredCapabilities = 3
        case externalPub = 4
        case externalSenders = 5
    }

    var type: UInt16
    var data: [UInt8]

    init(type: UInt16, data: [UInt8]) {
        self.type = type
        self.data = data
    }

    init(kind: Kind, data: [UInt8]) {
        self.init(type: kind.rawValue, data: data)
    }

    init(from reader: inout TLSReader) throws {
        type = try reader.readUInt16()
        data = try reader.readOpaque()
    }

    func encode(into writer: inout TLSWriter) throws {
        writer.write(type)
        try writer.writeOpaque(data)
    }
}

extension [MLSExtension] {
    func first(_ kind: MLSExtension.Kind) -> MLSExtension? {
        first { $0.type == kind.rawValue }
    }
}

/// `struct { SignaturePublicKey signature_key; Credential credential; }`
///
/// The voice gateway's own identity in the group. It is added as the single
/// entry of the `external_senders` group extension, and it is the only sender
/// whose proposals a DAVE client will act on.
struct ExternalSender: TLSCodable, Equatable {
    var signatureKey: [UInt8]
    var credential: Credential

    init(signatureKey: [UInt8], credential: Credential) {
        self.signatureKey = signatureKey
        self.credential = credential
    }

    init(from reader: inout TLSReader) throws {
        signatureKey = try reader.readOpaque()
        credential = try Credential(from: &reader)
    }

    func encode(into writer: inout TLSWriter) throws {
        try writer.writeOpaque(signatureKey)
        try credential.encode(into: &writer)
    }
}

/// The body of the `external_senders` extension: a vector of them, of which
/// DAVE requires there to be exactly one.
struct ExternalSendersExtension: TLSCodable, Equatable {
    var senders: [ExternalSender]

    init(senders: [ExternalSender]) { self.senders = senders }

    init(from reader: inout TLSReader) throws {
        senders = try reader.readVector(ExternalSender.self)
    }

    func encode(into writer: inout TLSWriter) throws {
        try writer.writeVector(senders)
    }
}

// MARK: Leaf nodes

enum LeafNodeSource: UInt8 {
    case keyPackage = 1
    case update = 2
    case commit = 3
}

/// One client's appearance in the tree, signed by that client.
struct LeafNode: TLSCodable, Equatable {
    /// The source discriminates a tail field, and it is the reason a leaf node
    /// cannot be a flat struct: a leaf in a key package carries a lifetime, one
    /// written by a commit carries the parent hash that chains it to the root,
    /// and one in an update carries neither.
    enum Source: Equatable {
        case keyPackage(Lifetime)
        case update
        case commit(parentHash: [UInt8])

        var tag: LeafNodeSource {
            switch self {
            case .keyPackage: .keyPackage
            case .update: .update
            case .commit: .commit
            }
        }
    }

    var encryptionKey: [UInt8]
    var signatureKey: [UInt8]
    var credential: Credential
    var capabilities: Capabilities
    var source: Source
    var extensions: [MLSExtension]
    var signature: [UInt8]

    init(
        encryptionKey: [UInt8],
        signatureKey: [UInt8],
        credential: Credential,
        capabilities: Capabilities,
        source: Source,
        extensions: [MLSExtension],
        signature: [UInt8]
    ) {
        self.encryptionKey = encryptionKey
        self.signatureKey = signatureKey
        self.credential = credential
        self.capabilities = capabilities
        self.source = source
        self.extensions = extensions
        self.signature = signature
    }

    init(from reader: inout TLSReader) throws {
        encryptionKey = try reader.readOpaque()
        signatureKey = try reader.readOpaque()
        credential = try Credential(from: &reader)
        capabilities = try Capabilities(from: &reader)
        let sourceTag = try reader.readByte()
        switch LeafNodeSource(rawValue: sourceTag) {
        case .keyPackage: source = .keyPackage(try Lifetime(from: &reader))
        case .update: source = .update
        case .commit: source = .commit(parentHash: try reader.readOpaque())
        case nil: throw MLSError.malformed("leaf node source \(sourceTag)")
        }
        extensions = try reader.readVector(MLSExtension.self)
        signature = try reader.readOpaque()
    }

    func encode(into writer: inout TLSWriter) throws {
        try encodeBody(into: &writer)
        try writer.writeOpaque(signature)
    }

    /// Everything but the signature — the shared prefix of `LeafNode` and
    /// `LeafNodeTBS`.
    private func encodeBody(into writer: inout TLSWriter) throws {
        try writer.writeOpaque(encryptionKey)
        try writer.writeOpaque(signatureKey)
        try credential.encode(into: &writer)
        try capabilities.encode(into: &writer)
        writer.write(source.tag.rawValue)
        switch source {
        case .keyPackage(let lifetime): try lifetime.encode(into: &writer)
        case .update: break
        case .commit(let parentHash): try writer.writeOpaque(parentHash)
        }
        try writer.writeVector(extensions)
    }

    /// `LeafNodeTBS` — the body, plus the group and leaf this node sits at when
    /// it was written by an update or a commit.
    ///
    /// **The group id and leaf index are what stop a leaf being lifted from one
    /// group into another**, so they are not optional context: a signature made
    /// without them would verify in a group the signer never joined.
    func signedContent(groupID: [UInt8], leafIndex: LeafIndex) throws -> [UInt8] {
        var writer = TLSWriter(reserving: 256)
        try encodeBody(into: &writer)
        switch source {
        case .keyPackage:
            break
        case .update, .commit:
            try writer.writeOpaque(groupID)
            writer.write(leafIndex)
        }
        return writer.bytes
    }

    func verifySignature(groupID: [UInt8], leafIndex: LeafIndex) throws {
        guard MLSCrypto.verify(
            publicKey: signatureKey,
            label: "LeafNodeTBS",
            content: try signedContent(groupID: groupID, leafIndex: leafIndex),
            signature: signature
        ) else { throw MLSError.badSignature("a leaf node") }
    }

    mutating func sign(
        with key: P256.Signing.PrivateKey, groupID: [UInt8], leafIndex: LeafIndex
    ) throws {
        signature = try MLSCrypto.sign(
            privateKey: key,
            label: "LeafNodeTBS",
            content: try signedContent(groupID: groupID, leafIndex: leafIndex)
        )
    }
}

// MARK: Key packages

/// What a pending member offers so somebody already in the group can add them.
struct KeyPackage: TLSCodable, Equatable {
    var version: UInt16
    var cipherSuite: UInt16
    var initKey: [UInt8]
    var leafNode: LeafNode
    var extensions: [MLSExtension]
    var signature: [UInt8]

    init(
        version: UInt16 = MLSCrypto.protocolVersion,
        cipherSuite: UInt16 = MLSCrypto.cipherSuiteID,
        initKey: [UInt8],
        leafNode: LeafNode,
        extensions: [MLSExtension] = [],
        signature: [UInt8] = []
    ) {
        self.version = version
        self.cipherSuite = cipherSuite
        self.initKey = initKey
        self.leafNode = leafNode
        self.extensions = extensions
        self.signature = signature
    }

    init(from reader: inout TLSReader) throws {
        version = try reader.readUInt16()
        cipherSuite = try reader.readUInt16()
        initKey = try reader.readOpaque()
        leafNode = try LeafNode(from: &reader)
        extensions = try reader.readVector(MLSExtension.self)
        signature = try reader.readOpaque()
    }

    func encode(into writer: inout TLSWriter) throws {
        try encodeBody(into: &writer)
        try writer.writeOpaque(signature)
    }

    private func encodeBody(into writer: inout TLSWriter) throws {
        writer.write(version)
        writer.write(cipherSuite)
        try writer.writeOpaque(initKey)
        try leafNode.encode(into: &writer)
        try writer.writeVector(extensions)
    }

    /// `KeyPackageTBS` — everything but the signature.
    func signedContent() throws -> [UInt8] {
        var writer = TLSWriter(reserving: 320)
        try encodeBody(into: &writer)
        return writer.bytes
    }

    mutating func sign(with key: P256.Signing.PrivateKey) throws {
        signature = try MLSCrypto.sign(
            privateKey: key, label: "KeyPackageTBS", content: try signedContent()
        )
    }

    func verifySignature() throws {
        guard MLSCrypto.verify(
            publicKey: leafNode.signatureKey,
            label: "KeyPackageTBS",
            content: try signedContent(),
            signature: signature
        ) else { throw MLSError.badSignature("a key package") }
    }

    /// `MakeKeyPackageRef` — how a welcome names the member it is for.
    func reference() throws -> [UInt8] {
        try MLSCrypto.keyPackageRef(try marshalled())
    }
}

// MARK: Tree nodes

struct ParentNode: TLSCodable, Equatable {
    var encryptionKey: [UInt8]
    var parentHash: [UInt8]
    /// Leaves added under this node since it was last set, which do **not**
    /// know its private key — so they count toward the node's resolution and
    /// have to be encrypted to separately.
    var unmergedLeaves: [LeafIndex]

    init(encryptionKey: [UInt8], parentHash: [UInt8], unmergedLeaves: [LeafIndex]) {
        self.encryptionKey = encryptionKey
        self.parentHash = parentHash
        self.unmergedLeaves = unmergedLeaves
    }

    init(from reader: inout TLSReader) throws {
        encryptionKey = try reader.readOpaque()
        parentHash = try reader.readOpaque()
        unmergedLeaves = try reader.readVector(UInt32.self)
    }

    func encode(into writer: inout TLSWriter) throws {
        try writer.writeOpaque(encryptionKey)
        try writer.writeOpaque(parentHash)
        try writer.writeVector(unmergedLeaves)
    }
}

/// One entry of a serialised ratchet tree.
enum TreeNode: TLSCodable, Equatable {
    case leaf(LeafNode)
    case parent(ParentNode)

    init(from reader: inout TLSReader) throws {
        let tag = try reader.readByte()
        switch tag {
        case 1: self = .leaf(try LeafNode(from: &reader))
        case 2: self = .parent(try ParentNode(from: &reader))
        default: throw MLSError.malformed("node type \(tag)")
        }
    }

    func encode(into writer: inout TLSWriter) throws {
        switch self {
        case .leaf(let node):
            writer.write(UInt8(1))
            try node.encode(into: &writer)
        case .parent(let node):
            writer.write(UInt8(2))
            try node.encode(into: &writer)
        }
    }
}

/// The body of the `ratchet_tree` extension: the flat node array, blanks and
/// all, as `optional<Node>`.
struct RatchetTreeExtension: TLSCodable, Equatable {
    var nodes: [TreeNode?]

    init(nodes: [TreeNode?]) { self.nodes = nodes }

    init(from reader: inout TLSReader) throws {
        let length = try reader.readVarint()
        var inner = TLSReader(try reader.readRaw(length))
        var nodes: [TreeNode?] = []
        while !inner.isAtEnd { nodes.append(try inner.readOptional(TreeNode.self)) }
        self.nodes = nodes
    }

    func encode(into writer: inout TLSWriter) throws {
        var inner = TLSWriter(reserving: 128 * max(nodes.count, 1))
        for node in nodes { try inner.writeOptional(node) }
        try writer.writeVarint(inner.bytes.count)
        writer.writeRaw(inner.bytes)
    }
}

// MARK: Update paths

struct HPKECiphertext: TLSCodable, Equatable {
    var kemOutput: [UInt8]
    var ciphertext: [UInt8]

    init(kemOutput: [UInt8], ciphertext: [UInt8]) {
        self.kemOutput = kemOutput
        self.ciphertext = ciphertext
    }

    init(_ sealed: MLSCrypto.HPKESealed) {
        self.init(kemOutput: sealed.kemOutput, ciphertext: sealed.ciphertext)
    }

    var sealed: MLSCrypto.HPKESealed {
        MLSCrypto.HPKESealed(kemOutput: kemOutput, ciphertext: ciphertext)
    }

    init(from reader: inout TLSReader) throws {
        kemOutput = try reader.readOpaque()
        ciphertext = try reader.readOpaque()
    }

    func encode(into writer: inout TLSWriter) throws {
        try writer.writeOpaque(kemOutput)
        try writer.writeOpaque(ciphertext)
    }
}

struct UpdatePathNode: TLSCodable, Equatable {
    var encryptionKey: [UInt8]
    /// One ciphertext per public key in the resolution of the copath child —
    /// the same path secret, sealed separately to everybody who needs it.
    var encryptedPathSecret: [HPKECiphertext]

    init(encryptionKey: [UInt8], encryptedPathSecret: [HPKECiphertext]) {
        self.encryptionKey = encryptionKey
        self.encryptedPathSecret = encryptedPathSecret
    }

    init(from reader: inout TLSReader) throws {
        encryptionKey = try reader.readOpaque()
        encryptedPathSecret = try reader.readVector(HPKECiphertext.self)
    }

    func encode(into writer: inout TLSWriter) throws {
        try writer.writeOpaque(encryptionKey)
        try writer.writeVector(encryptedPathSecret)
    }
}

struct UpdatePath: TLSCodable, Equatable {
    var leafNode: LeafNode
    var nodes: [UpdatePathNode]

    init(leafNode: LeafNode, nodes: [UpdatePathNode]) {
        self.leafNode = leafNode
        self.nodes = nodes
    }

    init(from reader: inout TLSReader) throws {
        leafNode = try LeafNode(from: &reader)
        nodes = try reader.readVector(UpdatePathNode.self)
    }

    func encode(into writer: inout TLSWriter) throws {
        try leafNode.encode(into: &writer)
        try writer.writeVector(nodes)
    }
}

// MARK: Group context

struct GroupContext: TLSCodable, Equatable {
    var version: UInt16 = MLSCrypto.protocolVersion
    var cipherSuite: UInt16 = MLSCrypto.cipherSuiteID
    var groupID: [UInt8]
    var epoch: UInt64
    var treeHash: [UInt8]
    var confirmedTranscriptHash: [UInt8]
    var extensions: [MLSExtension]

    init(
        groupID: [UInt8],
        epoch: UInt64,
        treeHash: [UInt8],
        confirmedTranscriptHash: [UInt8],
        extensions: [MLSExtension]
    ) {
        self.groupID = groupID
        self.epoch = epoch
        self.treeHash = treeHash
        self.confirmedTranscriptHash = confirmedTranscriptHash
        self.extensions = extensions
    }

    init(from reader: inout TLSReader) throws {
        version = try reader.readUInt16()
        cipherSuite = try reader.readUInt16()
        groupID = try reader.readOpaque()
        epoch = try reader.readUInt64()
        treeHash = try reader.readOpaque()
        confirmedTranscriptHash = try reader.readOpaque()
        extensions = try reader.readVector(MLSExtension.self)
    }

    func encode(into writer: inout TLSWriter) throws {
        writer.write(version)
        writer.write(cipherSuite)
        try writer.writeOpaque(groupID)
        writer.write(epoch)
        try writer.writeOpaque(treeHash)
        try writer.writeOpaque(confirmedTranscriptHash)
        try writer.writeVector(extensions)
    }
}

// MARK: Proposals

enum ProposalType: UInt16 {
    case add = 1
    case update = 2
    case remove = 3
}

enum Proposal: TLSCodable, Equatable {
    case add(KeyPackage)
    case update(LeafNode)
    case remove(LeafIndex)

    var type: ProposalType {
        switch self {
        case .add: .add
        case .update: .update
        case .remove: .remove
        }
    }

    /// RFC 9420 §12.4: a commit may omit its update path only when every
    /// proposal it covers is of a type that cannot need one. Add is the only
    /// such type DAVE ever sees.
    var requiresPath: Bool {
        switch self {
        case .add: false
        case .update, .remove: true
        }
    }

    init(from reader: inout TLSReader) throws {
        let type = try reader.readUInt16()
        switch ProposalType(rawValue: type) {
        case .add: self = .add(try KeyPackage(from: &reader))
        case .update: self = .update(try LeafNode(from: &reader))
        case .remove: self = .remove(try reader.readUInt32())
        case nil: throw MLSError.unsupportedProposal(type)
        }
    }

    func encode(into writer: inout TLSWriter) throws {
        writer.write(type.rawValue)
        switch self {
        case .add(let keyPackage): try keyPackage.encode(into: &writer)
        case .update(let leafNode): try leafNode.encode(into: &writer)
        case .remove(let leafIndex): writer.write(leafIndex)
        }
    }
}

enum ProposalOrRef: TLSCodable, Equatable {
    case proposal(Proposal)
    case reference([UInt8])

    init(from reader: inout TLSReader) throws {
        let tag = try reader.readByte()
        switch tag {
        case 1: self = .proposal(try Proposal(from: &reader))
        case 2: self = .reference(try reader.readOpaque())
        default: throw MLSError.malformed("proposal-or-ref type \(tag)")
        }
    }

    func encode(into writer: inout TLSWriter) throws {
        switch self {
        case .proposal(let proposal):
            writer.write(UInt8(1))
            try proposal.encode(into: &writer)
        case .reference(let reference):
            writer.write(UInt8(2))
            try writer.writeOpaque(reference)
        }
    }
}

struct Commit: TLSCodable, Equatable {
    var proposals: [ProposalOrRef]
    var path: UpdatePath?

    init(proposals: [ProposalOrRef], path: UpdatePath?) {
        self.proposals = proposals
        self.path = path
    }

    init(from reader: inout TLSReader) throws {
        proposals = try reader.readVector(ProposalOrRef.self)
        path = try reader.readOptional(UpdatePath.self)
    }

    func encode(into writer: inout TLSWriter) throws {
        try writer.writeVector(proposals)
        try writer.writeOptional(path)
    }
}

// MARK: Framing

enum SenderType: UInt8 {
    case member = 1
    case external = 2
    case newMemberProposal = 3
    case newMemberCommit = 4
}

enum Sender: TLSCodable, Equatable {
    case member(LeafIndex)
    case external(UInt32)
    case newMemberProposal
    case newMemberCommit

    var type: SenderType {
        switch self {
        case .member: .member
        case .external: .external
        case .newMemberProposal: .newMemberProposal
        case .newMemberCommit: .newMemberCommit
        }
    }

    init(from reader: inout TLSReader) throws {
        let tag = try reader.readByte()
        switch SenderType(rawValue: tag) {
        case .member: self = .member(try reader.readUInt32())
        case .external: self = .external(try reader.readUInt32())
        case .newMemberProposal: self = .newMemberProposal
        case .newMemberCommit: self = .newMemberCommit
        case nil: throw MLSError.malformed("sender type \(tag)")
        }
    }

    func encode(into writer: inout TLSWriter) throws {
        writer.write(type.rawValue)
        switch self {
        case .member(let index): writer.write(index)
        case .external(let index): writer.write(index)
        case .newMemberProposal, .newMemberCommit: break
        }
    }
}

enum ContentType: UInt8 {
    case application = 1
    case proposal = 2
    case commit = 3
}

struct FramedContent: TLSCodable, Equatable {
    enum Body: Equatable {
        case application([UInt8])
        case proposal(Proposal)
        case commit(Commit)

        var type: ContentType {
            switch self {
            case .application: .application
            case .proposal: .proposal
            case .commit: .commit
            }
        }
    }

    var groupID: [UInt8]
    var epoch: UInt64
    var sender: Sender
    var authenticatedData: [UInt8]
    var body: Body

    init(
        groupID: [UInt8], epoch: UInt64, sender: Sender,
        authenticatedData: [UInt8], body: Body
    ) {
        self.groupID = groupID
        self.epoch = epoch
        self.sender = sender
        self.authenticatedData = authenticatedData
        self.body = body
    }

    init(from reader: inout TLSReader) throws {
        groupID = try reader.readOpaque()
        epoch = try reader.readUInt64()
        sender = try Sender(from: &reader)
        authenticatedData = try reader.readOpaque()
        let tag = try reader.readByte()
        switch ContentType(rawValue: tag) {
        case .application: body = .application(try reader.readOpaque())
        case .proposal: body = .proposal(try Proposal(from: &reader))
        case .commit: body = .commit(try Commit(from: &reader))
        case nil: throw MLSError.malformed("content type \(tag)")
        }
    }

    func encode(into writer: inout TLSWriter) throws {
        try writer.writeOpaque(groupID)
        writer.write(epoch)
        try sender.encode(into: &writer)
        try writer.writeOpaque(authenticatedData)
        writer.write(body.type.rawValue)
        switch body {
        case .application(let data): try writer.writeOpaque(data)
        case .proposal(let proposal): try proposal.encode(into: &writer)
        case .commit(let commit): try commit.encode(into: &writer)
        }
    }
}

struct FramedContentAuthData: Equatable {
    var signature: [UInt8]
    /// Present only on a commit, and it is what proves the sender arrived at
    /// the same epoch as everybody else.
    var confirmationTag: [UInt8]?

    init(signature: [UInt8], confirmationTag: [UInt8]?) {
        self.signature = signature
        self.confirmationTag = confirmationTag
    }

    init(from reader: inout TLSReader, contentType: ContentType) throws {
        signature = try reader.readOpaque()
        confirmationTag = contentType == .commit ? try reader.readOpaque() : nil
    }

    func encode(into writer: inout TLSWriter, contentType: ContentType) throws {
        try writer.writeOpaque(signature)
        if contentType == .commit {
            try writer.writeOpaque(confirmationTag ?? [])
        }
    }
}

enum WireFormat: UInt16 {
    case publicMessage = 1
    case privateMessage = 2
    case welcome = 3
    case groupInfo = 4
    case keyPackage = 5
}

/// A signed, unencrypted handshake message.
///
/// **DAVE never sends a `PrivateMessage`.** Every handshake message is a
/// `PublicMessage`, which the whitepaper requires so the voice gateway can
/// inspect a commit and refuse an invalid one. It is transport-encrypted to the
/// server but not end-to-end encrypted between members, and the protocol says
/// so out loud.
struct PublicMessage: TLSCodable, Equatable {
    var content: FramedContent
    var auth: FramedContentAuthData
    /// Present only when a member sent it: proof the sender is in the group.
    var membershipTag: [UInt8]?

    init(content: FramedContent, auth: FramedContentAuthData, membershipTag: [UInt8]?) {
        self.content = content
        self.auth = auth
        self.membershipTag = membershipTag
    }

    init(from reader: inout TLSReader) throws {
        content = try FramedContent(from: &reader)
        auth = try FramedContentAuthData(from: &reader, contentType: content.body.type)
        membershipTag = content.sender.type == .member ? try reader.readOpaque() : nil
    }

    func encode(into writer: inout TLSWriter) throws {
        try content.encode(into: &writer)
        try auth.encode(into: &writer, contentType: content.body.type)
        if content.sender.type == .member {
            try writer.writeOpaque(membershipTag ?? [])
        }
    }
}

/// `AuthenticatedContent` — a `PublicMessage` with its wire format and without
/// the membership tag. It is what a proposal reference hashes over, so its
/// serialisation has to be exact even though it never goes on a socket.
struct AuthenticatedContent: TLSCodable, Equatable {
    var wireFormat: WireFormat
    var content: FramedContent
    var auth: FramedContentAuthData

    init(wireFormat: WireFormat, content: FramedContent, auth: FramedContentAuthData) {
        self.wireFormat = wireFormat
        self.content = content
        self.auth = auth
    }

    init(from reader: inout TLSReader) throws {
        let format = try reader.readUInt16()
        guard let wire = WireFormat(rawValue: format) else {
            throw MLSError.unsupportedWireFormat(format)
        }
        wireFormat = wire
        content = try FramedContent(from: &reader)
        auth = try FramedContentAuthData(from: &reader, contentType: content.body.type)
    }

    func encode(into writer: inout TLSWriter) throws {
        writer.write(wireFormat.rawValue)
        try content.encode(into: &writer)
        try auth.encode(into: &writer, contentType: content.body.type)
    }

    /// `MakeProposalRef` — how a commit names a proposal it covers.
    func reference() throws -> [UInt8] {
        try MLSCrypto.proposalRef(try marshalled())
    }
}

// MARK: Welcome

struct EncryptedGroupSecrets: TLSCodable, Equatable {
    var newMember: [UInt8]
    var encryptedGroupSecrets: HPKECiphertext

    init(newMember: [UInt8], encryptedGroupSecrets: HPKECiphertext) {
        self.newMember = newMember
        self.encryptedGroupSecrets = encryptedGroupSecrets
    }

    init(from reader: inout TLSReader) throws {
        newMember = try reader.readOpaque()
        encryptedGroupSecrets = try HPKECiphertext(from: &reader)
    }

    func encode(into writer: inout TLSWriter) throws {
        try writer.writeOpaque(newMember)
        try encryptedGroupSecrets.encode(into: &writer)
    }
}

struct Welcome: TLSCodable, Equatable {
    var cipherSuite: UInt16 = MLSCrypto.cipherSuiteID
    var secrets: [EncryptedGroupSecrets]
    var encryptedGroupInfo: [UInt8]

    init(secrets: [EncryptedGroupSecrets], encryptedGroupInfo: [UInt8]) {
        self.secrets = secrets
        self.encryptedGroupInfo = encryptedGroupInfo
    }

    init(from reader: inout TLSReader) throws {
        cipherSuite = try reader.readUInt16()
        secrets = try reader.readVector(EncryptedGroupSecrets.self)
        encryptedGroupInfo = try reader.readOpaque()
    }

    func encode(into writer: inout TLSWriter) throws {
        writer.write(cipherSuite)
        try writer.writeVector(secrets)
        try writer.writeOpaque(encryptedGroupInfo)
    }
}

/// The per-joiner payload inside a welcome.
///
/// `psks` is parsed and required to be empty: DAVE injects no pre-shared keys,
/// and a welcome that carried one would take the key schedule somewhere this
/// client cannot follow. Reading the field and rejecting a non-empty one is the
/// honest handling; skipping it would misparse the rest of the structure.
struct GroupSecrets: TLSCodable, Equatable {
    var joinerSecret: [UInt8]
    var pathSecret: [UInt8]?
    var preSharedKeys: [PreSharedKeyID]

    init(joinerSecret: [UInt8], pathSecret: [UInt8]?, preSharedKeys: [PreSharedKeyID] = []) {
        self.joinerSecret = joinerSecret
        self.pathSecret = pathSecret
        self.preSharedKeys = preSharedKeys
    }

    init(from reader: inout TLSReader) throws {
        joinerSecret = try reader.readOpaque()
        pathSecret = try reader.readOptional(TLSOpaque.self)?.bytes
        preSharedKeys = try reader.readVector(PreSharedKeyID.self)
    }

    func encode(into writer: inout TLSWriter) throws {
        try writer.writeOpaque(joinerSecret)
        try writer.writeOptional(pathSecret.map(TLSOpaque.init))
        try writer.writeVector(preSharedKeys)
    }
}

struct PreSharedKeyID: TLSCodable, Equatable {
    enum Identity: Equatable {
        case external(id: [UInt8])
        case resumption(usage: UInt8, groupID: [UInt8], epoch: UInt64)
    }

    var identity: Identity
    var nonce: [UInt8]

    init(identity: Identity, nonce: [UInt8]) {
        self.identity = identity
        self.nonce = nonce
    }

    init(from reader: inout TLSReader) throws {
        let type = try reader.readByte()
        switch type {
        case 1:
            identity = .external(id: try reader.readOpaque())
        case 2:
            identity = .resumption(
                usage: try reader.readByte(),
                groupID: try reader.readOpaque(),
                epoch: try reader.readUInt64()
            )
        default:
            throw MLSError.malformed("PSK type \(type)")
        }
        nonce = try reader.readOpaque()
    }

    func encode(into writer: inout TLSWriter) throws {
        switch identity {
        case .external(let id):
            writer.write(UInt8(1))
            try writer.writeOpaque(id)
        case .resumption(let usage, let groupID, let epoch):
            writer.write(UInt8(2))
            writer.write(usage)
            try writer.writeOpaque(groupID)
            writer.write(epoch)
        }
        try writer.writeOpaque(nonce)
    }
}

// MARK: Group info

struct GroupInfo: TLSCodable, Equatable {
    var groupContext: GroupContext
    var extensions: [MLSExtension]
    var confirmationTag: [UInt8]
    var signer: LeafIndex
    var signature: [UInt8]

    init(
        groupContext: GroupContext,
        extensions: [MLSExtension],
        confirmationTag: [UInt8],
        signer: LeafIndex,
        signature: [UInt8] = []
    ) {
        self.groupContext = groupContext
        self.extensions = extensions
        self.confirmationTag = confirmationTag
        self.signer = signer
        self.signature = signature
    }

    init(from reader: inout TLSReader) throws {
        groupContext = try GroupContext(from: &reader)
        extensions = try reader.readVector(MLSExtension.self)
        confirmationTag = try reader.readOpaque()
        signer = try reader.readUInt32()
        signature = try reader.readOpaque()
    }

    func encode(into writer: inout TLSWriter) throws {
        try encodeBody(into: &writer)
        try writer.writeOpaque(signature)
    }

    private func encodeBody(into writer: inout TLSWriter) throws {
        try groupContext.encode(into: &writer)
        try writer.writeVector(extensions)
        try writer.writeOpaque(confirmationTag)
        writer.write(signer)
    }

    func signedContent() throws -> [UInt8] {
        var writer = TLSWriter(reserving: 512)
        try encodeBody(into: &writer)
        return writer.bytes
    }

    mutating func sign(with key: P256.Signing.PrivateKey) throws {
        signature = try MLSCrypto.sign(
            privateKey: key, label: "GroupInfoTBS", content: try signedContent()
        )
    }

    func verifySignature(publicKey: [UInt8]) throws {
        guard MLSCrypto.verify(
            publicKey: publicKey,
            label: "GroupInfoTBS",
            content: try signedContent(),
            signature: signature
        ) else { throw MLSError.badSignature("a group info") }
    }
}

// MARK: The outer envelope

/// `MLSMessage` — the versioned, wire-format-tagged wrapper.
///
/// **Not everything DAVE sends is wrapped in one.** A key package goes on the
/// voice gateway bare, and so does a welcome; only commits and proposals travel
/// as `MLSMessage`. See `DAVEOpcode` for which is which and why.
enum MLSMessage: TLSCodable, Equatable {
    case publicMessage(PublicMessage)
    case welcome(Welcome)
    case groupInfo(GroupInfo)
    case keyPackage(KeyPackage)

    var wireFormat: WireFormat {
        switch self {
        case .publicMessage: .publicMessage
        case .welcome: .welcome
        case .groupInfo: .groupInfo
        case .keyPackage: .keyPackage
        }
    }

    init(from reader: inout TLSReader) throws {
        let version = try reader.readUInt16()
        guard version == MLSCrypto.protocolVersion else {
            throw MLSError.unsupportedVersion(version)
        }
        let format = try reader.readUInt16()
        switch WireFormat(rawValue: format) {
        case .publicMessage: self = .publicMessage(try PublicMessage(from: &reader))
        case .welcome: self = .welcome(try Welcome(from: &reader))
        case .groupInfo: self = .groupInfo(try GroupInfo(from: &reader))
        case .keyPackage: self = .keyPackage(try KeyPackage(from: &reader))
        case .privateMessage, nil: throw MLSError.unsupportedWireFormat(format)
        }
    }

    func encode(into writer: inout TLSWriter) throws {
        writer.write(MLSCrypto.protocolVersion)
        writer.write(wireFormat.rawValue)
        switch self {
        case .publicMessage(let message): try message.encode(into: &writer)
        case .welcome(let welcome): try welcome.encode(into: &writer)
        case .groupInfo(let info): try info.encode(into: &writer)
        case .keyPackage(let keyPackage): try keyPackage.encode(into: &writer)
        }
    }

    /// The group a handshake message is for, without committing to processing
    /// it — used to refuse a commit that belongs to somebody else's call.
    var groupID: [UInt8]? {
        if case .publicMessage(let message) = self { return message.content.groupID }
        return nil
    }
}
