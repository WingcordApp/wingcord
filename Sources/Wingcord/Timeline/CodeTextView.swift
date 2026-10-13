import AppKit
import SwiftUI

/// Text set as Discord's code view (`.codeView__4d95d`): 14-point monospace
/// on 16-point lines, tabs four spaces wide.
///
/// **A text view, not a `Text`.** The lines are Discord's 16 points — tighter
/// than the face's own leading, which only a paragraph style can set — and
/// the text is selectable as Discord's is, ⌘A included, which an AppKit text
/// view does natively.
enum CodeText {
    static let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    static let lineHeight: CGFloat = 16

    /// Plain code in the reader's ink.
    static func plain(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: attributes)
    }

    static let attributes: [NSAttributedString.Key: Any] = {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        // `tab-size: 4`, in this face's own space.
        let space = (" " as NSString).size(withAttributes: [.font: font]).width
        paragraph.tabStops = []
        paragraph.defaultTabInterval = space * 4
        // The line is 16 and the face is taller: the baseline is moved down
        // by half of what was taken, so the glyphs sit centred as CSS's
        // half-leading centres them.
        let natural = font.ascender - font.descender + font.leading
        return [
            .font: font,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
            .baselineOffset: (lineHeight - natural) / 2,
        ]
    }()

    /// A read-only text view with no inset, no padding and no ground: the
    /// card around it is Discord's box.
    static func makeTextView() -> NSTextView {
        let view = NSTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.isAutomaticLinkDetectionEnabled = false
        return view
    }
}

/// A short run of code — a preview card's lines — sized to its text: as wide
/// as it is offered when it wraps, as wide as its longest line when it does
/// not.
struct CodeTextView: NSViewRepresentable {
    var text: NSAttributedString
    var wraps: Bool

    func makeNSView(context: Context) -> NSTextView {
        let view = CodeText.makeTextView()
        view.textContainer?.widthTracksTextView = false
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        guard view.textStorage?.isEqual(to: text) != true else { return }
        view.textStorage?.setAttributedString(text)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NSTextView, context: Context) -> CGSize? {
        guard let container = view.textContainer, let layout = view.layoutManager else { return nil }
        let offered = proposal.width ?? .greatestFiniteMagnitude
        container.size = CGSize(width: wraps ? offered : .greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        return CGSize(
            width: wraps && offered.isFinite ? offered : used.width.rounded(.up),
            height: max(CodeText.lineHeight, used.height.rounded(.up))
        )
    }
}

/// A whole file of code in its own scroller — View whole file's text, where
/// 50 KB is laid out lazily by the text system rather than all at once.
struct CodeDocumentView: NSViewRepresentable {
    var text: NSAttributedString
    var wraps: Bool
    /// The room around the text, inside the scroller.
    var inset: CGFloat

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let view = CodeText.makeTextView()
        view.minSize = .zero
        view.maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.textContainerInset = CGSize(width: inset, height: inset)
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, let container = view.textContainer else { return }
        if view.textStorage?.isEqual(to: text) != true {
            view.textStorage?.setAttributedString(text)
        }
        // Wrapped, the text follows the scroller's width; unwrapped, each
        // line runs as long as it is and the scroller scrolls sideways too.
        guard container.widthTracksTextView != wraps else { return }
        scroll.hasHorizontalScroller = !wraps
        view.isHorizontallyResizable = !wraps
        container.widthTracksTextView = wraps
        container.size = CGSize(
            width: wraps ? scroll.contentSize.width : .greatestFiniteMagnitude,
            height: .greatestFiniteMagnitude
        )
        if wraps { view.frame.size.width = scroll.contentSize.width }
    }
}
