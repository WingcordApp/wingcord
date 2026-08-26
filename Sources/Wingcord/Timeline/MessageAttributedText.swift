import AppKit
import CoreText
import Foundation
import WingcordCore

/// Turns a parsed message into an attributed string CoreText can lay out.
///
/// Two properties matter more than anything else here:
///
/// **Inline emoji are `CTRunDelegate` placeholders, not views.** An object
/// replacement character carrying a run delegate reserves exactly the right
/// ascent, descent and width in the line, so the text wraps around the emoji
/// correctly and the painter draws the picture into the rect the delegate
/// reserved. The alternative — hosting a view per emoji — puts an AppKit view
/// inside every message that has one, which is the cost the canvas exists to
/// avoid.
///
/// **The plain label is folded here, once.** A message paragraph carries link
/// attributes on its mentions, its channel chips and its URLs, and the
/// accessibility layer re-resolves every such run into attributes on **every
/// render** — reaching localized bundle string tables to answer what font a run
/// is in, per run, per frame, whether or not anyone is using VoiceOver. One
/// plain `String` label on one accessibility node removes all of it.
/// `@unchecked Sendable`: `attributed` is an immutable `NSAttributedString` —
/// `finish()` copies the mutable builder output rather than handing out the
/// buffer it was assembling into, so nothing can mutate it after the fact.
nonisolated struct MessageText: @unchecked Sendable {
    /// What CoreText lays out.
    let attributed: NSAttributedString
    /// Custom emoji, by the character index of their placeholder.
    let inlineEmoji: [Int: EmojiRef]
    /// Link destinations, by character range.
    let links: [LinkRun]
    /// Spoiler ranges, concealed until revealed.
    let spoilers: [NSRange]
    /// The folded plain text, for one accessibility node.
    let plainLabel: String

    struct LinkRun: Sendable {
        var range: NSRange
        var target: LinkTarget
    }

    enum LinkTarget: Hashable, Sendable {
        case url(String)
        case user(UserID)
        case role(RoleID)
        case channel(ChannelID)
    }
}

/// Everything the builder needs from the session to resolve a mention into a
/// name. A value, so building a message's text never touches the store.
nonisolated struct MentionContext: Sendable {
    var userNames: [UserID: String] = [:]
    var roleNames: [RoleID: String] = [:]
    var roleColors: [RoleID: UInt32] = [:]
    var channelNames: [ChannelID: String] = [:]
    /// The reader's own ids, so a mention of them is drawn differently.
    var selfIDs: Set<UInt64> = []

    /// A token that changes whenever any of the above could change.
    ///
    /// **This is the memo key, and it has to carry every input.** A cache keyed
    /// on the message text alone serves whichever surface rendered it first — so
    /// an embed rendered in a context with no names caches the placeholder form
    /// (`@user`, `#channel`) and the transcript then serves that to everyone,
    /// forever. Closures have no identity to hash; a generation does.
    var token: UInt64 = 0
}

nonisolated enum MessageTextBuilder {

    /// Builds the attributed form.
    ///
    /// `nonisolated` and free of store access, so it can run on the layout task
    /// rather than on the main actor.
    static func build(
        document: MarkdownDocument,
        context: MentionContext,
        style: MessageTextStyle
    ) -> MessageText {
        var builder = Builder(context: context, style: style)
        builder.append(document.blocks)
        return builder.finish(plainLabel: document.plainText)
    }

    private struct Builder {
        let context: MentionContext
        let style: MessageTextStyle
        var output = NSMutableAttributedString()
        var inlineEmoji: [Int: EmojiRef] = [:]
        var links: [MessageText.LinkRun] = []
        var spoilers: [NSRange] = []

        mutating func append(_ blocks: [BlockNode]) {
            for (index, block) in blocks.enumerated() {
                if index > 0 { appendRaw("\n", attributes: style.body) }
                append(block)
            }
        }

        mutating func append(_ block: BlockNode) {
            switch block {
            case .paragraph(let nodes):
                append(nodes, attributes: style.body)
            case .heading(let level, let nodes):
                append(nodes, attributes: style.heading(level: level))
            case .subtext(let nodes):
                append(nodes, attributes: style.subtext)
            case .codeBlock(_, let code):
                appendRaw(code, attributes: style.codeBlock)
            case .quote(let children):
                // The quote's leading rule is painted by the row painter from
                // the paragraph's measured rect; here it is only an indent, so
                // the text wraps inside the rule rather than under it.
                let start = output.length
                append(children)
                let range = NSRange(location: start, length: output.length - start)
                if range.length > 0 {
                    output.addAttribute(.paragraphStyle, value: style.quoteParagraph, range: range)
                }
            case .list(let ordered, let startIndex, let items):
                for (offset, item) in items.enumerated() {
                    if offset > 0 { appendRaw("\n", attributes: style.body) }
                    let marker = ordered ? "\(startIndex + offset). " : "• "
                    appendRaw(marker, attributes: style.listMarker)
                    for child in item { append(child) }
                }
            }
        }

        mutating func append(_ nodes: [InlineNode], attributes: [NSAttributedString.Key: Any]) {
            for node in nodes {
                switch node {
                case .text(let value):
                    appendRaw(value, attributes: attributes)

                case .styled(let inlineStyle, let children):
                    var merged = attributes
                    style.apply(inlineStyle, to: &merged)
                    let start = output.length
                    append(children, attributes: merged)
                    if inlineStyle.contains(.spoiler) {
                        spoilers.append(NSRange(location: start, length: output.length - start))
                    }

                case .code(let value):
                    appendRaw(value, attributes: style.inlineCode)

                case .link(let label, let url):
                    let start = output.length
                    append(label, attributes: style.link(base: attributes))
                    links.append(.init(
                        range: NSRange(location: start, length: output.length - start),
                        target: .url(url)
                    ))

                case .autoLink(let url):
                    let start = output.length
                    appendRaw(url, attributes: style.link(base: attributes))
                    links.append(.init(
                        range: NSRange(location: start, length: output.length - start),
                        target: .url(url)
                    ))

                case .userMention(let userID):
                    let name = context.userNames[userID].map { "@\($0)" } ?? "@unknown"
                    appendMention(
                        name,
                        base: attributes,
                        isSelf: context.selfIDs.contains(userID.rawValue),
                        target: .user(userID)
                    )

                case .roleMention(let roleID):
                    let name = context.roleNames[roleID].map { "@\($0)" } ?? "@role"
                    appendMention(
                        name,
                        base: attributes,
                        isSelf: context.selfIDs.contains(roleID.rawValue),
                        tint: context.roleColors[roleID],
                        target: .role(roleID)
                    )

                case .channelMention(let channelID):
                    let name = context.channelNames[channelID].map { "#\($0)" } ?? "#channel"
                    appendMention(name, base: attributes, isSelf: false, target: .channel(channelID))

                case .commandMention(let name, _):
                    appendMention("/\(name)", base: attributes, isSelf: false, target: nil)

                case .everyoneMention:
                    appendMention("@everyone", base: attributes, isSelf: true, target: nil)

                case .hereMention:
                    appendMention("@here", base: attributes, isSelf: true, target: nil)

                case .customEmoji(let emoji):
                    appendInlineEmoji(emoji, base: attributes)

                case .timestamp(let date, let timestampStyle):
                    appendMention(
                        style.format(date, style: timestampStyle),
                        base: attributes,
                        isSelf: false,
                        target: nil
                    )

                case .lineBreak:
                    appendRaw("\n", attributes: attributes)
                }
            }
        }

        mutating func appendRaw(_ value: String, attributes: [NSAttributedString.Key: Any]) {
            guard !value.isEmpty else { return }
            output.append(NSAttributedString(string: value, attributes: attributes))
        }

        mutating func appendMention(
            _ label: String,
            base: [NSAttributedString.Key: Any],
            isSelf: Bool,
            tint: UInt32? = nil,
            target: MessageText.LinkTarget? = nil
        ) {
            let start = output.length
            appendRaw(label, attributes: style.mention(base: base, isSelf: isSelf, tint: tint))
            if let target {
                links.append(.init(
                    range: NSRange(location: start, length: output.length - start),
                    target: target
                ))
            }
        }

        /// Inserts an object-replacement character carrying a run delegate that
        /// reserves the emoji's box.
        ///
        /// The delegate's callbacks are C function pointers with no captured
        /// state, so the metrics are read from a boxed value passed as the
        /// delegate's `refCon` — which is retained and released by the two
        /// lifecycle callbacks so it lives exactly as long as the delegate does.
        mutating func appendInlineEmoji(
            _ emoji: EmojiRef,
            base: [NSAttributedString.Key: Any]
        ) {
            let index = output.length
            inlineEmoji[index] = emoji

            let metrics = InlineBoxMetrics(
                ascent: style.emojiAscent,
                descent: style.emojiDescent,
                width: style.emojiWidth
            )
            var attributes = base
            if let delegate = InlineBoxMetrics.makeRunDelegate(metrics) {
                attributes[kCTRunDelegateAttributeName as NSAttributedString.Key] = delegate
            }
            output.append(NSAttributedString(string: "\u{FFFC}", attributes: attributes))
        }

        func finish(plainLabel: String) -> MessageText {
            MessageText(
                // A copy, not the builder's own buffer: handing out the mutable
                // instance would let a later append change a string another
                // thread is already laying out.
                attributed: NSAttributedString(attributedString: output),
                inlineEmoji: inlineEmoji,
                links: links,
                spoilers: spoilers,
                plainLabel: plainLabel
            )
        }
    }
}

/// The box an inline image reserves in a line.
nonisolated final class InlineBoxMetrics: @unchecked Sendable {
    let ascent: CGFloat
    let descent: CGFloat
    let width: CGFloat

    init(ascent: CGFloat, descent: CGFloat, width: CGFloat) {
        self.ascent = ascent
        self.descent = descent
        self.width = width
    }

    static func makeRunDelegate(_ metrics: InlineBoxMetrics) -> CTRunDelegate? {
        var callbacks = CTRunDelegateCallbacks(
            version: kCTRunDelegateCurrentVersion,
            dealloc: { pointer in
                Unmanaged<InlineBoxMetrics>.fromOpaque(pointer).release()
            },
            getAscent: { pointer in
                Unmanaged<InlineBoxMetrics>.fromOpaque(pointer).takeUnretainedValue().ascent
            },
            getDescent: { pointer in
                Unmanaged<InlineBoxMetrics>.fromOpaque(pointer).takeUnretainedValue().descent
            },
            getWidth: { pointer in
                Unmanaged<InlineBoxMetrics>.fromOpaque(pointer).takeUnretainedValue().width
            }
        )
        let retained = Unmanaged.passRetained(metrics).toOpaque()
        guard let delegate = CTRunDelegateCreate(&callbacks, retained) else {
            Unmanaged<InlineBoxMetrics>.fromOpaque(retained).release()
            return nil
        }
        return delegate
    }
}
