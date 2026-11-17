import Foundation

/// Discord's **Components V2** tree: a message whose entire body is built out of
/// components rather than out of `content` and `embeds`.
///
/// An app that posts this way sends `content: ""` and no embeds at all, so a
/// renderer that only knows those two draws an author line, a timestamp and a
/// blank space — which on a release or roadmap channel is the whole channel.
/// `MessageFlags.isComponentsV2` is the tell, and this is what it points at.
///
/// **Only the nodes that carry something a reader can see are modelled.** The
/// tree keeps growing; a decoder that throws on an unknown node throws away the
/// whole message page it arrived in, so anything unrecognised is skipped and
/// anything empty is dropped.
public indirect enum DisplayComponent: Hashable, Sendable, Codable {
    /// A card with an optional accent rule down its leading edge. The one node
    /// that draws a ground; everything else is content.
    case container(accent: UInt32?, children: [DisplayComponent])
    /// Text with an optional picture pinned to its trailing edge.
    case section(children: [DisplayComponent], thumbnail: Embed.Media?)
    /// Markdown. Mentions, channel chips, custom emoji and code all resolve here
    /// exactly as they do in a message body — which is what makes an app's
    /// custom emoji render at all.
    case text(String)
    /// A rule, or a gap where `isDivider` is false.
    case separator(isDivider: Bool, isLarge: Bool)
    case gallery([Embed.Media])
    /// Controls, in tree order. Kept in the tree rather than hoisted, so a row
    /// declared inside a container is drawn inside it.
    case row(ActionRow)

    /// Whether this node would draw nothing at all.
    ///
    /// An empty container is a bordered box around a gap, and an empty section
    /// is a thumbnail with nothing beside it.
    public var isEmpty: Bool {
        switch self {
        case .container(_, let children): children.allSatisfy(\.isEmpty)
        case .section(let children, let thumbnail): children.allSatisfy(\.isEmpty) && thumbnail == nil
        case .text(let value): value.isEmpty
        case .separator: false
        case .gallery(let items): items.isEmpty
        case .row(let row): row.components.isEmpty
        }
    }

    /// The first control anywhere in a tree that satisfies `predicate`.
    ///
    /// **The tree, not the top level.** A V2 message keeps its rows where the
    /// application declared them — inside a container, inside a section — and
    /// the pager in `slash help.har` is nested exactly that way. A search that
    /// only looked at the roots would find no button on the one message shape
    /// this is for.
    public static func firstControl(
        in nodes: [DisplayComponent],
        where predicate: (MessageComponent) -> Bool
    ) -> MessageComponent? {
        for node in nodes {
            switch node {
            case .row(let row):
                if let match = row.components.first(where: predicate) { return match }
            case .container(_, let children), .section(let children, _):
                if let match = firstControl(in: children, where: predicate) { return match }
            case .text, .separator, .gallery:
                continue
            }
        }
        return nil
    }

    /// The plain text of this subtree, for one accessibility label.
    ///
    /// Folded once at layout time for the same reason `MarkdownDocument.plainText`
    /// is: a row is one accessibility node with a plain `String`, because letting
    /// the platform derive a label from styled text re-resolves every run into
    /// attributes on every render.
    public var plainText: String {
        switch self {
        case .container(_, let children), .section(let children, _):
            children.map(\.plainText).filter { !$0.isEmpty }.joined(separator: "\n")
        case .text(let value):
            value
        case .separator, .gallery:
            ""
        case .row(let row):
            row.components.map(\.label).filter { !$0.isEmpty }.joined(separator: ", ")
        }
    }
}

extension DisplayComponent {
    /// Every text display in a tree, in reading order, a blank line between
    /// two — what Copy Text puts on the pasteboard for a message built of
    /// components, whose `content` is empty.
    public static func plainText(of nodes: [DisplayComponent]) -> String {
        var parts: [String] = []
        func walk(_ nodes: [DisplayComponent]) {
            for node in nodes {
                switch node {
                case .text(let value) where !value.isEmpty: parts.append(value)
                case .container(_, let children), .section(let children, _): walk(children)
                default: break
                }
            }
        }
        walk(nodes)
        return parts.joined(separator: "\n\n")
    }
}
