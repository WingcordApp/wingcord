import AppKit

/// A key an editor's owner may want before the text does.
enum EditorKey: Equatable {
    case up, down, tab, backspace, escape
    /// Return, and whether Shift was held — which is a new line, not a send.
    case `return`(shift: Bool)
}

/// The text view under every markdown field: plain text only, TextKit 2, the
/// placeholder drawn in the caret's own line, and the keys and focus its owner
/// asks about reported out.
final class MarkdownTextView: NSTextView {
    var placeholder: NSAttributedString?
    var onFocusChange: ((Bool) -> Void)?
    /// The selection came to rest — a drag let go, or a keyboard selection
    /// made. What brings the formatting toolbar up.
    var onSelectionSettled: (() -> Void)?
    /// ⌘B, ⌘I and ⌘U: the three formats a keyboard has a habit for.
    var onFormatShortcut: ((MarkdownFormat) -> Void)?

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }
    /// Text only, so a file dragged over the field falls through to the
    /// composer's own drop target rather than landing as a path.
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] { [.string] }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange?(false) }
        return resigned
    }

    override func setSelectedRanges(
        _ ranges: [NSValue],
        affinity: NSSelectionAffinity,
        stillSelecting: Bool
    ) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if !stillSelecting { onSelectionSettled?() }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard window?.firstResponder === self, flags == .command, let key = event.charactersIgnoringModifiers
        else { return super.performKeyEquivalent(with: event) }
        let format: MarkdownFormat? = switch key {
        case "b": .bold
        case "i": .italics
        case "u": .underline
        default: nil
        }
        guard let format, let onFormatShortcut else { return super.performKeyEquivalent(with: event) }
        onFormatShortcut(format)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, let placeholder else { return }
        let origin = textContainerOrigin
        let padding = textContainer?.lineFragmentPadding ?? 0
        placeholder.draw(at: CGPoint(x: origin.x + padding, y: origin.y))
    }
}

/// The scroll view a markdown field grows inside: one line to its ceiling, then
/// it scrolls.
final class MarkdownEditorContainer: NSScrollView {
    let textView: MarkdownTextView
    var lines: ClosedRange<Int> = 1...8 {
        didSet { if lines != oldValue { remeasure() } }
    }
    /// The height the field wants at its width, reported whenever it moves.
    var onHeightChange: ((CGFloat) -> Void)?
    private(set) var fittedHeight: CGFloat = 0

    init() {
        textView = MarkdownTextView(usingTextLayoutManager: true)
        super.init(frame: .zero)
        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        scrollerStyle = .overlay
        verticalScrollElasticity = .none
        horizontalScrollElasticity = .none

        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.textContainerInset = .zero
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        documentView = textView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - frame.width) >= 0.5
        super.setFrameSize(newSize)
        if widthChanged { remeasure() }
    }

    /// Measures the text at the current width and reports the height the
    /// field should take: its content, held between the least and the most
    /// lines it may show.
    func remeasure() {
        guard let manager = textView.textLayoutManager, let font = textView.font else { return }
        manager.ensureLayout(for: manager.documentRange)
        let content = manager.usageBoundsForTextContainer.height
        let line = ceil(font.ascender - font.descender + font.leading)
        let lower = line * CGFloat(lines.lowerBound)
        let upper = line * CGFloat(lines.upperBound)
        let height = min(max(ceil(content), lower), upper)
        guard abs(height - fittedHeight) >= 0.5 else { return }
        fittedHeight = height
        onHeightChange?(height)
    }
}
