import Foundation

/// A run of inline content inside one paragraph.
public indirect enum InlineNode: Hashable, Sendable {
    case text(String)
    case styled(InlineStyle, [InlineNode])
    /// Inline code. Never contains child nodes — everything inside a code span
    /// is literal, which is the entire point of the span.
    case code(String)
    /// A markdown link: `[label](url)`.
    case link(label: [InlineNode], url: String)
    /// A bare URL that appeared in prose.
    case autoLink(String)
    case userMention(UserID)
    case roleMention(RoleID)
    case channelMention(ChannelID)
    case commandMention(name: String, id: UInt64)
    case customEmoji(EmojiRef)
    case everyoneMention
    case hereMention
    /// `<t:1234567890:F>` — a moment rendered in the reader's own time zone and
    /// locale, which is why it is a node and not text.
    case timestamp(Date, TimestampStyle)
    /// `<id:guide>` and its kin — a place in the server rather than a channel.
    /// `itemID` is the role in `<id:linked-roles:123>`.
    case staticRoute(StaticRoute, itemID: UInt64?)
    case lineBreak
}

/// A place in a server that a message can point at by name — Discord's
/// `staticRouteLink`, `<id:guide>`.
///
/// **Exactly Discord's five** (`/^<id:(home|browse|customize|guide|linked-roles)
/// (?::(\d+))?>/`); anything else in that shape stays text, as it does there.
public enum StaticRoute: String, Hashable, Sendable, CaseIterable {
    case home
    case browse
    case customize
    case guide
    case linkedRoles = "linked-roles"

    /// What the chip says — Discord's strings, `home` and `guide` sharing one.
    public var title: String {
        switch self {
        case .home, .guide: "Server Guide"
        case .browse: "Browse Channels"
        case .customize: "Channels & Roles"
        case .linkedRoles: "Linked Roles"
        }
    }
}

public struct InlineStyle: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let bold = InlineStyle(rawValue: 1 << 0)
    public static let italic = InlineStyle(rawValue: 1 << 1)
    public static let underline = InlineStyle(rawValue: 1 << 2)
    public static let strikethrough = InlineStyle(rawValue: 1 << 3)
    public static let spoiler = InlineStyle(rawValue: 1 << 4)
}

public enum TimestampStyle: Character, Hashable, Sendable {
    case shortTime = "t"
    case longTime = "T"
    case shortDate = "d"
    case longDate = "D"
    case shortDateTime = "f"
    case longDateTime = "F"
    case relative = "R"
}

/// A block-level element.
public indirect enum BlockNode: Hashable, Sendable {
    case paragraph([InlineNode])
    case heading(level: Int, [InlineNode])
    /// `-# small text`, Discord's subtext.
    case subtext([InlineNode])
    case codeBlock(language: String?, code: String)
    case quote([BlockNode])
    case list(ordered: Bool, startIndex: Int, items: [[BlockNode]])
}

/// A parsed message body.
public struct MarkdownDocument: Hashable, Sendable {
    public var blocks: [BlockNode]

    public init(blocks: [BlockNode]) { self.blocks = blocks }

    public static let empty = MarkdownDocument(blocks: [])

    public var isEmpty: Bool { blocks.isEmpty }

    /// The plain-text form, for an accessibility label, a notification body or a
    /// channel-list preview.
    ///
    /// **This is why the parse is worth keeping around.** Folding the tree once
    /// per message is how a row can carry one accessibility node with a plain
    /// `String` label. The alternative — letting the platform derive a label
    /// from styled text carrying link attributes — makes the accessibility layer
    /// re-resolve every text run into attributes on every render, per frame,
    /// whether or not anyone is using VoiceOver, because on a real Mac something
    /// always holds the accessibility API open.
    public var plainText: String {
        var out = ""
        for (index, block) in blocks.enumerated() {
            if index > 0 { out += "\n" }
            Self.appendPlain(block, to: &out)
        }
        return out
    }

    private static func appendPlain(_ block: BlockNode, to out: inout String) {
        switch block {
        case .paragraph(let nodes), .subtext(let nodes):
            appendPlain(nodes, to: &out)
        case .heading(_, let nodes):
            appendPlain(nodes, to: &out)
        case .codeBlock(_, let code):
            out += code
        case .quote(let children):
            for (index, child) in children.enumerated() {
                if index > 0 { out += "\n" }
                appendPlain(child, to: &out)
            }
        case .list(_, _, let items):
            for (index, item) in items.enumerated() {
                if index > 0 { out += "\n" }
                for child in item { appendPlain(child, to: &out) }
            }
        }
    }

    private static func appendPlain(_ nodes: [InlineNode], to out: inout String) {
        for node in nodes {
            switch node {
            case .text(let value), .code(let value), .autoLink(let value):
                out += value
            case .styled(_, let children), .link(let children, _):
                appendPlain(children, to: &out)
            case .userMention: out += "@user"
            case .roleMention: out += "@role"
            case .channelMention: out += "#channel"
            case .staticRoute(let route, _): out += route.title
            case .commandMention(let name, _): out += "/\(name)"
            case .customEmoji(let emoji): out += ":\(emoji.name):"
            case .everyoneMention: out += "@everyone"
            case .hereMention: out += "@here"
            case .timestamp: out += "time"
            case .lineBreak: out += "\n"
            }
        }
    }
}
