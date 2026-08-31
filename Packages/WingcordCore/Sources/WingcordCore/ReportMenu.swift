import Foundation

/// The questionnaire Discord serves for a report, as a graph.
///
/// **The whole flow is data, not code.** `GET /reporting/menu/{message|user}`
/// answers with a node table, a root, and children naming other nodes by id;
/// the client walks it and posts the ids it walked. Hard-coding the questions
/// would mean shipping a client whose report categories go stale the week
/// Discord adds one — and the categories are the entire content of the flow.
///
/// Everything here is a plain value. The tree is decoded once per subject kind,
/// cached for the session, and walked by a `ReportPath` that holds no reference
/// back into it.
public struct ReportMenu: Hashable, Sendable {
    /// `"message"` or `"user"`. Goes back in the submission, and is what names
    /// the postback route.
    public var name: String
    /// Discord's own experiment/version pair. Echoed back verbatim: the
    /// submission is only meaningful against the tree it was walked in.
    public var variant: String
    public var version: String
    public var rootNodeID: Int
    public var nodes: [Int: ReportNode]

    public init(
        name: String,
        variant: String,
        version: String,
        rootNodeID: Int,
        nodes: [Int: ReportNode]
    ) {
        self.name = name
        self.variant = variant
        self.version = version
        self.rootNodeID = rootNodeID
        self.nodes = nodes
    }

    public subscript(id: Int) -> ReportNode? { nodes[id] }
    public var root: ReportNode? { nodes[rootNodeID] }
}

/// One screen of the flow.
public struct ReportNode: Hashable, Sendable, Identifiable {
    public var id: Int
    public var header: String
    public var subheader: String?
    /// A standing warning shown above the choices — "If there is immediate
    /// danger, contact emergency help as soon as possible." It is not a
    /// subheader: it appears on nodes that already have one.
    public var info: String?
    public var button: ReportButton?
    public var elements: [ReportElement]
    /// Present on a node that is a leaf of the taxonomy. Its presence is what
    /// makes a node submittable at all.
    public var reportType: String?
    public var children: [ReportChoice]
    /// A node that posts the moment it is reached, then shows its own header as
    /// the acknowledgement. Discord uses it for the two signal-only categories
    /// — "I don't like it" and "rude language" — which are collected and never
    /// answered.
    public var isAutoSubmit: Bool

    public init(
        id: Int,
        header: String,
        subheader: String? = nil,
        info: String? = nil,
        button: ReportButton? = nil,
        elements: [ReportElement] = [],
        reportType: String? = nil,
        children: [ReportChoice] = [],
        isAutoSubmit: Bool = false
    ) {
        self.id = id
        self.header = header
        self.subheader = subheader
        self.info = info
        self.button = button
        self.elements = elements
        self.reportType = reportType
        self.children = children
        self.isAutoSubmit = isAutoSubmit
    }

    /// Whether reaching this node ends the flow with a post.
    public var submits: Bool {
        if isAutoSubmit { return true }
        if case .submit = button { return true }
        return false
    }
}

public struct ReportChoice: Hashable, Sendable, Identifiable {
    public var label: String
    public var nodeID: Int
    public var id: Int { nodeID }

    public init(label: String, nodeID: Int) {
        self.label = label
        self.nodeID = nodeID
    }
}

/// The one button under a node, when it has one.
///
/// A node with `children` needs none — each child is its own row. A node with
/// neither is a dead end and is treated as `done`.
public enum ReportButton: Hashable, Sendable {
    case submit
    case cancel
    case done
    /// Continue to a node that is not a child — an interstitial, or the shared
    /// summary screen every checkbox page funnels into.
    case next(Int)
}

/// The parts of a node the client is asked to draw.
///
/// **Only what this client can honour is modelled.** Discord's list also names
/// upsells for its own settings, a "share with parents" flow and a mute this
/// client has no route for; those decode to `.decoration` and draw nothing,
/// rather than becoming controls that answer nothing — `INVARIANTS.md` §5.5.
public enum ReportElement: Hashable, Sendable {
    /// The message being reported, quoted.
    case subjectPreview
    /// The path taken so far, as the summary screen's list.
    case breadcrumbs
    case externalLink(text: String, url: URL)
    /// A multi-select. `options` is `(value, label)`; the values are what goes
    /// back under `name`.
    case checkbox(name: String, options: [ReportOption])
    /// An action offered *after* the report lands — block, ignore, delete.
    case followUp(ReportFollowUp)
    /// Something this client draws nothing for.
    case decoration
}

public struct ReportOption: Hashable, Sendable, Identifiable {
    public var value: String
    public var label: String
    public var id: String { value }

    public init(value: String, label: String) {
        self.value = value
        self.label = label
    }
}

/// What the acknowledgement screen offers to do next.
public enum ReportFollowUp: String, Hashable, Sendable {
    case block
    case ignore
    case deleteMessage
}

// MARK: - Walking it

/// Where a report has got to, and what it has collected.
///
/// **A value, so the whole flow is checkable without a network or a view.** The
/// failure mode of a report flow is a submission whose breadcrumbs describe a
/// path the reader did not take, and that is a pure-data bug — which is exactly
/// the kind a value type lets a test catch.
public struct ReportPath: Hashable, Sendable {
    /// Node ids, root first. This is literally what the submission carries.
    public private(set) var nodeIDs: [Int]
    /// The label of each choice taken, so the summary can list them without
    /// walking the tree again.
    public private(set) var labels: [String]
    /// Collected element data, by element name.
    public private(set) var selections: [String: Set<String>]

    public init(root: Int) {
        nodeIDs = [root]
        labels = []
        selections = [:]
    }

    public var currentNodeID: Int { nodeIDs[nodeIDs.count - 1] }
    public var canGoBack: Bool { nodeIDs.count > 1 }

    /// Moves to `nodeID`. `label` is nil for a button-driven step, which
    /// contributes a breadcrumb id and no line to the summary.
    public mutating func push(_ nodeID: Int, label: String?) {
        nodeIDs.append(nodeID)
        if let label { labels.append(label) }
    }

    public mutating func pop() {
        guard canGoBack else { return }
        nodeIDs.removeLast()
        if !labels.isEmpty { labels.removeLast() }
    }

    public mutating func toggle(_ value: String, in element: String) {
        var chosen = selections[element] ?? []
        if chosen.remove(value) == nil { chosen.insert(value) }
        // An empty set is removed rather than kept: the submission's `elements`
        // object carries only what was actually chosen, and a key holding an
        // empty array is a claim the reader did not make.
        selections[element] = chosen.isEmpty ? nil : chosen
    }

    public func isChosen(_ value: String, in element: String) -> Bool {
        selections[element]?.contains(value) ?? false
    }

    /// Whether the node's own requirement is met — a checkbox page needs at
    /// least one box.
    public func satisfies(_ node: ReportNode) -> Bool {
        for element in node.elements {
            guard case .checkbox(let name, _) = element else { continue }
            if selections[name]?.isEmpty ?? true { return false }
        }
        return true
    }

    /// The `elements` object of the submission: name to the chosen values, in
    /// the order the node offered them.
    public func submissionElements(in menu: ReportMenu) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for id in nodeIDs {
            guard let node = menu[id] else { continue }
            for element in node.elements {
                guard case .checkbox(let name, let options) = element,
                      let chosen = selections[name], !chosen.isEmpty
                else { continue }
                result[name] = options.map(\.value).filter(chosen.contains)
            }
        }
        return result
    }
}
