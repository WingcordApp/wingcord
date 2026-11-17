import SwiftUI
import WingcordCore

/// A channel's topic as a browse row draws it: Discord's markup drawn rather
/// than shown.
///
/// **The row used to print the wire string** (Alex, 2026-11-17), so a server's
/// `**Read the rules**` and `<#1234>` reached the list as asterisks and digits.
/// This is the tree the transcript paints, folded into one run of styled text:
/// bold, italics, code, strikes and links keep their look, a spoiler stays
/// covered, and a mention reads as the name it points at. Newlines become
/// spaces — a two-line preview has no room for a blank one.
///
/// **A `Text`, not `ProseText`.** A row is a button, and prose is an `NSView`
/// per instance with a selection of its own: a category of fifty channels would
/// be fifty canvases for lines nobody selects.
@MainActor
enum ChannelTopicPreview {
    /// Keyed on the mention table's token as well as the words, so a renamed
    /// channel or role is never served under its old name (`MentionContext.token`).
    private static var cache: [String: AttributedString] = [:]
    private static let cacheLimit = 2_000

    static func attributed(
        _ markdown: String,
        mentions: MentionContext,
        userName: @escaping (UserID) -> String?
    ) -> AttributedString {
        let key = "\(mentions.token)\u{1}\(markdown)"
        if let hit = cache[key] { return hit }
        var folder = Folder(mentions: mentions, userName: userName)
        for block in MarkdownParser().parse(markdown).blocks {
            folder.append(block)
        }
        // A name not known yet is drawn as Discord's placeholder and asked
        // again next time, rather than kept: the token doesn't move with people.
        guard !folder.isProvisional else { return folder.out }
        if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
        cache[key] = folder.out
        return folder.out
    }

    private struct Folder {
        var mentions: MentionContext
        var userName: (UserID) -> String?
        var out = AttributedString()
        /// Whether a mention was drawn as a placeholder for want of its name.
        var isProvisional = false
        /// Whether the next words need a space before them: a new block, or a
        /// line break inside one.
        private var needsSpace = false

        init(mentions: MentionContext, userName: @escaping (UserID) -> String?) {
            self.mentions = mentions
            self.userName = userName
        }

        mutating func append(_ block: BlockNode) {
            switch block {
            case .paragraph(let nodes), .subtext(let nodes):
                separate()
                append(nodes, style: [])
            case .heading(_, let nodes):
                separate()
                append(nodes, style: .bold)
            case .codeBlock(_, let code):
                separate()
                var piece = AttributedString(Self.oneLine(code))
                piece.inlinePresentationIntent = .code
                out.append(piece)
            case .quote(let children):
                for child in children { append(child) }
            case .list(_, _, let items):
                for item in items {
                    separate()
                    out.append(AttributedString("• "))
                    for child in item { append(child) }
                }
            }
        }

        private mutating func separate() {
            if !out.characters.isEmpty, out.characters.last?.isWhitespace == false {
                out.append(AttributedString(" "))
            }
            needsSpace = false
        }

        /// - Parameter tint: a link's colour, for the words of its label.
        private mutating func append(_ nodes: [InlineNode], style: InlineStyle, tint: Color? = nil) {
            for node in nodes {
                switch node {
                case .text(let value):
                    words(Self.oneLine(value), style: style, tint: tint)
                case .code(let value):
                    words(Self.oneLine(value), style: style, isCode: true, tint: tint)
                case .autoLink(let value):
                    words(value, style: style, tint: Palette.accent)
                case .styled(let inner, let children):
                    append(children, style: style.union(inner), tint: tint)
                case .link(let label, _):
                    append(label, style: style, tint: Palette.accent)
                case .userMention(let id):
                    let name = mentions.userNames[id] ?? userName(id)
                    if name == nil { isProvisional = true }
                    chip("@" + (name ?? "unknown-user"), tint: Palette.accent)
                case .roleMention(let id):
                    let role = mentions.roles[id]
                    if role == nil { isProvisional = true }
                    chip("@" + (role?.name ?? "deleted-role"), tint: role?.color.map { Color(hex: $0) } ?? Palette.accent)
                case .channelMention(let id):
                    let channel = mentions.channels[id]
                    if channel == nil { isProvisional = true }
                    chip("#" + (channel?.name ?? "unknown"), tint: Palette.accent)
                case .commandMention(let name, _):
                    chip("/" + name, tint: Palette.accent)
                case .gameMention(let id):
                    chip(mentions.gameNames[id] ?? "game", tint: Palette.accent)
                case .everyoneMention:
                    chip("@everyone", tint: Palette.accent)
                case .hereMention:
                    chip("@here", tint: Palette.accent)
                case .staticRoute(let route, _):
                    chip(route.title, tint: Palette.accent)
                case .timestamp(let date, let timestampStyle):
                    chip(timestampStyle.format(date), tint: InkColor.primary)
                case .customEmoji(let emoji):
                    words(":\(emoji.name):", style: style, tint: tint)
                case .lineBreak:
                    needsSpace = true
                }
            }
        }

        private mutating func words(_ value: String, style: InlineStyle, isCode: Bool = false, tint: Color? = nil) {
            guard !value.isEmpty else { return }
            if needsSpace {
                separate()
            }
            var piece = AttributedString(value)
            var intent: InlinePresentationIntent = []
            if style.contains(.bold) { intent.insert(.stronglyEmphasized) }
            if style.contains(.italic) { intent.insert(.emphasized) }
            if style.contains(.strikethrough) { intent.insert(.strikethrough) }
            if isCode { intent.insert(.code) }
            if !intent.isEmpty { piece.inlinePresentationIntent = intent }
            if style.contains(.underline) { piece.underlineStyle = .single }
            if let tint { piece.foregroundColor = tint }
            // Covered, as Discord's spoiler is until it's clicked — and a
            // preview is never clicked open.
            if style.contains(.spoiler) {
                piece.foregroundColor = .clear
                piece.backgroundColor = InkColor.tertiary
            }
            out.append(piece)
        }

        /// A mention: its name in its colour, on a wash of it — the transcript's
        /// chip, at a preview's size.
        private mutating func chip(_ name: String, tint: Color) {
            if needsSpace { separate() }
            var piece = AttributedString(name)
            piece.foregroundColor = tint
            piece.backgroundColor = tint.opacity(0.16)
            out.append(piece)
        }

        private static func oneLine(_ value: String) -> String {
            guard value.contains(where: \.isNewline) else { return value }
            return value.split(whereSeparator: \.isNewline).joined(separator: " ")
        }
    }
}
