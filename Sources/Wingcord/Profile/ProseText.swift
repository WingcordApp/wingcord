import AppKit
import SwiftUI
import WingcordCore

/// Discord markdown outside the transcript: a bio, a channel's topic, an event's
/// description, an app's overview.
///
/// **The transcript's own text, in a view of its own.** This used to be a flow of
/// per-word SwiftUI views, which could be laid out and never used: a selection has
/// nothing to run across when every word is a separate view, a spoiler was clear ink
/// on a plate with nothing listening for a click, and a mention had nowhere to go
/// (Alex, 2026-11-04: "i cant copy any bio text or interact with spoilers"). So this
/// builds the same `MessageText` a message does, lays it out with the same
/// `TimelineTextBlock` and paints it with the same `TimelineRowPainter`, and
/// `ProseCanvasView` answers the pointer. Selection, ⌘C, spoilers, links, mentions,
/// chips, timestamps and emoji all behave as they do in a message, because they are
/// the same code.
///
/// **Honours `.lineLimit`**, which the flow never could: it limited each word.
///
/// The parse is cached process-wide: a profile card's body runs again on every
/// hover of every badge in it, and re-scanning the same bio each time is work with a
/// known answer.
struct ProseText: View {
    var markdown: String
    var font: Font
    var color: Color
    /// The side an inline custom emoji is drawn at. Derived by the caller from
    /// the text size, so a picture in a line of prose grows with the words.
    var emojiSide: CGFloat = 18
    /// Resolves mentions to names. Nil renders them in their placeholder form,
    /// which is what a surface with no session behind it can honestly say.
    var mentions: MentionContext?
    /// What a click on a custom emoji does. Nil makes them inert pictures.
    var onEmoji: ((EmojiRef) -> Void)?
    /// Whether a click on an emoji opens its card here, pointing at the emoji.
    ///
    /// **The card used to be the surface's, and so was its anchor**: one
    /// popover on the whole profile, which opened at the profile's edge however
    /// far away the emoji was. The prose knows where the picture is, so the
    /// prose presents — one presentation per block of prose, never one per
    /// emoji. Takes the click instead of `onEmoji` where both are given.
    var inspectsEmoji = false
    /// What a click on a link does. Nil draws links as ordinary accent text and
    /// takes no clicks, which is the honest answer on a surface with nothing to
    /// open them with — `INVARIANTS.md` §5.5.
    var onLink: ((String) -> Void)?
    /// Whether this prose's animated emoji may move at all, before the
    /// reader's own preferences are asked.
    ///
    /// **The DM column passes its hover.** It stays on screen for as long as
    /// the conversation does, and Discord plays a sidebar bio's emoji only
    /// while the pointer is on the sidebar (`animateOnHoverOrFocusOnly`).
    /// Everywhere else the prose was opened to be read, and plays.
    var animates = true
    /// The words' weight, for prose that is a title. Regular everywhere else.
    var weight: NSFont.Weight = .regular
    /// Whether the words can be selected. **Off only inside something pressable**,
    /// an event card you click to open: there a press on plain words is the card's,
    /// while a link or a spoiler in them still answers for itself.
    var isSelectable = true

    @Environment(\.lineLimit) private var lineLimit
    @Environment(\.colorScheme) private var colorScheme
    /// Where a mention or a chip goes. Optional, because a preview surface draws
    /// prose with no session behind it.
    @Environment(AppModel.self) private var model: AppModel?
    @State private var inspected: ProseInspectedEmoji?

    /// A click on an emoji: the card here where this prose presents it, the
    /// caller's closure otherwise.
    private var emojiAction: ((EmojiRef, CGRect) -> Void)? {
        if inspectsEmoji {
            return { emoji, rect in inspected = ProseInspectedEmoji(emoji: emoji, rect: rect) }
        }
        guard let onEmoji else { return nil }
        return { emoji, _ in onEmoji(emoji) }
    }

    var body: some View {
        ProseCanvasHost(
            markdown: markdown,
            pointSize: NSFont.resolved(font).pointSize,
            weight: weight,
            color: color,
            isLight: colorScheme == .light,
            emojiSide: emojiSide,
            lineLimit: lineLimit,
            plays: animates,
            mentions: mentions ?? MentionContext(),
            selectsText: isSelectable,
            actions: ProseCanvasView.Actions(emoji: emojiAction, follow: follow)
        )
        // On the canvas itself, before any frame: the rect is in its space.
        .modifier(ProseEmojiInspector(isOn: inspectsEmoji, inspected: $inspected))
        .frame(maxWidth: .infinity, alignment: .leading)
        // **An `NSView` has no baseline to offer**, so a row that lines up on first
        // baselines (an icon beside an event's place) would use its foot. The font's
        // ascent is where the first line's baseline falls.
        .alignmentGuide(.firstTextBaseline) { [ascent = NSFont.resolved(font).ascender] in $0[.top] + ascent }
        .accessibilityElement(children: .ignore)
        // One plain string for one node, exactly as a transcript row carries.
        .accessibilityLabel(Text(ProseCache.shared.document(for: markdown).plainText))
    }

    /// Where a click on a link, a mention or a chip goes. The transcript's
    /// routing, with the caller's opener for anything that is a web address, since
    /// some surfaces do something first (`openLinkFromEvents` leaves the page).
    private var follow: ((MessageText.LinkTarget, CGRect) -> Void)? {
        guard let onLink else { return nil }
        let model = model
        let guildID = mentions?.currentGuildID
        return { target, anchor in
            switch target {
            case .url(let string):
                onLink(string)
            case .channelLink(let link, let url):
                if let url {
                    onLink(url)
                } else {
                    model?.openChannelLink(link, fallbackURL: nil)
                }
            case .user(let userID):
                model?.openProfile(userID, anchor: anchor)
            case .role(let roleID):
                guard let model, let guildID = guildID ?? model.selectedGuildID else { return }
                model.openRoleMembers(roleID, inGuild: guildID, anchor: anchor)
            case .staticRoute(let route, let itemID):
                model?.openStaticRoute(route, itemID: itemID, anchor: anchor)
            case .game(let gameID):
                model?.openGameProfile(gameID)
            }
        }
    }
}

/// The view, fed from SwiftUI.
///
/// **The colours are resolved here**, against this view's environment, so prose on
/// a pale profile in a dark app gets the card's ink rather than the window's.
private struct ProseCanvasHost: NSViewRepresentable {
    var markdown: String
    var pointSize: CGFloat
    var weight: NSFont.Weight
    var color: Color
    var isLight: Bool
    var emojiSide: CGFloat
    var lineLimit: Int?
    var plays: Bool
    var mentions: MentionContext
    var selectsText: Bool
    var actions: ProseCanvasView.Actions

    func makeNSView(context: Context) -> ProseCanvasView { ProseCanvasView() }

    func updateNSView(_ view: ProseCanvasView, context: Context) {
        let environment = context.environment
        view.configure(
            drawing: ProseDrawing(
                markdown: markdown,
                pointSize: pointSize,
                primary: color.resolve(in: environment),
                secondary: InkColor.secondary.resolve(in: environment),
                tertiary: InkColor.tertiary.resolve(in: environment),
                accent: Palette.accent.resolve(in: environment),
                isLight: isLight,
                emojiSide: emojiSide,
                lineLimit: lineLimit,
                plays: plays && AnimationClock.playsAnimatedEmoji,
                weight: weight
            ),
            mentions: mentions,
            actions: actions,
            selectsText: selectsText
        )
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ProseCanvasView, context: Context) -> CGSize? {
        nsView.size(for: proposal)
    }

    static func dismantleNSView(_ view: ProseCanvasView, coordinator: ()) {
        view.tearDown()
    }
}

// MARK: - The parse cache

/// Parsed prose, held for the process.
///
/// A profile card's body runs again on every hover of every badge in it, and
/// re-scanning the same bio each time is work with a known answer. Bounded by
/// `NSCache`, which evicts under pressure on its own — these are strings, not
/// pixels, so the ceiling is generous and the cost of a miss is a rescan.
final class ProseCache: @unchecked Sendable {
    static let shared = ProseCache()

    private let cache = NSCache<NSString, Box>()
    private let parser = MarkdownParser()
    private let lock = NSLock()

    private final class Box {
        let document: MarkdownDocument
        init(_ document: MarkdownDocument) { self.document = document }
    }

    private init() { cache.countLimit = 128 }

    func document(for markdown: String) -> MarkdownDocument {
        let key = markdown as NSString
        if let hit = cache.object(forKey: key) { return hit.document }
        lock.lock()
        defer { lock.unlock() }
        let parsed = parser.parse(markdown)
        cache.setObject(Box(parsed), forKey: key)
        return parsed
    }
}

extension NSFont {
    /// The AppKit font a SwiftUI `Font` resolves to, for measurement only.
    ///
    /// SwiftUI does not publish this, and prose is laid out by CoreText. The mapping
    /// covers the text styles this app actually draws prose in; anything else
    /// falls back to the body, which is the right shape if not the right size.
    static func resolved(_ font: Font) -> NSFont {
        .preferredFont(forTextStyle: proseStyles.first { $0.font == font }?.style ?? .body)
    }

    /// Both spellings of each, since `Font.caption` and `Font.system(.caption)` are
    /// not the same value, and the call sites use both.
    private static let proseStyles: [(font: Font, style: NSFont.TextStyle)] = [
        (.caption, .caption1), (.system(.caption), .caption1),
        (.caption2, .caption2), (.system(.caption2), .caption2),
        (.footnote, .footnote), (.system(.footnote), .footnote),
        (.subheadline, .subheadline), (.system(.subheadline), .subheadline),
        (.callout, .callout), (.system(.callout), .callout),
        (.headline, .headline), (.system(.headline), .headline),
        (.title3, .title3), (.system(.title3), .title3),
    ]
}
