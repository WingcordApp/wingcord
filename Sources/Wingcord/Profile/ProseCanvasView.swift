import AppKit
import SwiftUI
import WingcordCore

/// What a piece of prose draws, compared whole so nothing is rebuilt for nothing.
struct ProseDrawing: Equatable {
    var markdown: String
    var pointSize: CGFloat
    var primary: Color.Resolved
    var secondary: Color.Resolved
    var tertiary: Color.Resolved
    var accent: Color.Resolved
    var isLight: Bool
    var emojiSide: CGFloat
    var lineLimit: Int?
    var plays: Bool
    /// The words' own weight — a title set in prose, as a game announcement's
    /// is. Bold in the markdown stays bold over it.
    var weight: NSFont.Weight = .regular

    /// The transcript's style at this size and in this ink.
    func style() -> MessageTextStyle {
        let base = MessageTextStyle.current(scale: 1)
        var style = base.scaled(pointSize / base.bodyFont.pointSize)
        style.primaryColor = NSColor(cgColor: primary.cgColor) ?? style.primaryColor
        style.secondaryColor = NSColor(cgColor: secondary.cgColor) ?? style.secondaryColor
        style.tertiaryColor = NSColor(cgColor: tertiary.cgColor) ?? style.tertiaryColor
        let accentColor = NSColor(cgColor: accent.cgColor) ?? style.linkColor
        style.linkColor = accentColor
        style.mentionColor = accentColor
        // `scaled` leaves this alone, being the transcript's small face. Here it's
        // subtext, which is Discord's 13 against a 16 body.
        style.metadataFont = NSFont.systemFont(ofSize: pointSize * 0.8125)
        style.criticalColor = MessageTextStyle.criticalInk(isLight: isLight)
        style.codePalette = CodePalette(room: .init(
            isLight: isLight,
            highContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        ))
        if weight != .regular {
            style.bodyFont = NSFont.systemFont(ofSize: style.bodyFont.pointSize, weight: weight)
        }
        style.emojiWidth = emojiSide
        style.emojiAscent = emojiSide * 0.78
        style.emojiDescent = emojiSide * 0.22
        return style
    }
}

/// One piece of prose on screen: drawn with the transcript's painter, and answering
/// the pointer as a message does. See `ProseText`.
///
/// **Press and release, not press.** A link or an emoji goes on release, because a
/// drag that starts on one is a selection. A spoiler lifts on press, as Discord's
/// does, and a press on it starts nothing else.
final class ProseCanvasView: NSView, NSMenuItemValidation {

    struct Actions {
        /// A click on an emoji, with its rect in this view's own space — which
        /// is the representable's, so SwiftUI can hang a card on the picture
        /// itself rather than on the whole surface.
        var emoji: ((EmojiRef, CGRect) -> Void)?
        /// Where a link, mention or chip goes. Nil takes no clicks. The rect is the
        /// run's, in the hosting root's space, for whatever opens beside it.
        var follow: ((MessageText.LinkTarget, CGRect) -> Void)?
    }

    /// What a press landed on, kept until the release decides.
    private enum Pressed {
        case emoji(EmojiRef, CGRect)
        case link(MessageText.LinkTarget, CGRect)
    }

    private var drawing: ProseDrawing?
    private var mentions = MentionContext()
    private var actions = Actions()
    private var selectsText = true

    private var style: MessageTextStyle?
    private var text: MessageText?
    private var plates: TextPlateInk?
    /// Layouts by width, in half points. SwiftUI asks at more widths than it uses.
    private var blocks: [Int: TimelineTextBlock] = [:]
    private var block: TimelineTextBlock?

    /// Which spoilers the reader has lifted. Closing the surface puts them back.
    private var revealedSpoilers: Set<Int> = []
    private var hoveredSpoiler: Int?
    private var hoveredLink: MessageText.LinkTarget?
    private var hoveredPlate: Int?

    private var selection: (anchor: Int, focus: Int)?
    private var isDragging = false
    private var pressed: Pressed?
    private var pressOrigin: CGPoint = .zero
    /// A click elsewhere puts a selection down, as it does in any text.
    private var clickMonitor: Any?

    private var films: [Int: FilmPlayer] = [:]
    /// The emoji whose film has frames up, which the painter leaves to the layer.
    private var layeredEmoji: Set<Int> = []
    private var requestedImages: Set<ImageStore.Key> = []

    /// How far a press may wander and still be a click.
    private static let clickSlop: CGFloat = 3

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { selectsText }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func isAccessibilityElement() -> Bool { false }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.masksToBounds = false
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        MainActor.assumeIsolated { tearDown() }
    }

    // MARK: What to draw

    func configure(
        drawing new: ProseDrawing,
        mentions newMentions: MentionContext,
        actions newActions: Actions,
        selectsText selectable: Bool
    ) {
        actions = newActions
        selectsText = selectable
        let isSame = new == drawing && newMentions.token == mentions.token
            // A fenced block drew plain while highlight.js was answering.
            && text?.awaitsHighlighting != true
        guard !isSame else { return }

        if new.markdown != drawing?.markdown {
            revealedSpoilers = []
            clearSelection()
            hoveredSpoiler = nil
            hoveredLink = nil
            hoveredPlate = nil
            // Different words, so these indexes mean different emoji.
            for film in films.values { film.tearDown() }
            films = [:]
            layeredEmoji = []
        }
        drawing = new
        mentions = newMentions
        let style = new.style()
        self.style = style
        plates = ThemeInk.current.plates(isLight: new.isLight)
        text = MessageTextBuilder.build(
            document: ProseCache.shared.document(for: new.markdown),
            context: newMentions,
            style: style
        )
        blocks = [:]
        block = nil
        needsLayout = true
        needsDisplay = true
    }

    /// Takes down what outlives a view on its own: the films and the click monitor.
    func tearDown() {
        for film in films.values { film.tearDown() }
        films = [:]
        layeredEmoji = []
        removeClickMonitor()
    }

    /// What SwiftUI should make room for at this width.
    func size(for proposal: ProposedViewSize) -> CGSize {
        guard text != nil else { return .zero }
        if let width = proposal.width, width.isFinite {
            // A probe for how small this can go: one line, at nothing wide.
            guard width >= 1 else { return CGSize(width: 0, height: drawing?.pointSize ?? 0) }
            return CGSize(width: width, height: layout(width: width).size.height)
        }
        return layout(width: 100_000, hugsText: true).size
    }

    /// The block at this width, clamped to the line limit.
    private func layout(width: CGFloat, hugsText: Bool = false) -> TimelineTextBlock {
        let key = hugsText ? -1 : Int((width * 2).rounded())
        if let hit = blocks[key] { return hit }
        guard let text, let style else { fatalError("laid out before configure") }
        var result = TimelineTextBlock(text: text, width: width, style: style, hugsText: hugsText)
        if let limit = drawing?.lineLimit, limit > 0, result.lineCount > limit,
           let clamped = Self.clamped(text, in: result, to: limit, width: width, style: style) {
            result = clamped
        }
        if blocks.count > 4 { blocks = [:] }
        blocks[key] = result
        return result
    }

    /// The text cut so an ellipsis ends the last line allowed.
    ///
    /// Backs up a little at a time, because the ellipsis has to fit too, and on a
    /// full line it would otherwise wrap to a line of its own.
    private static func clamped(
        _ text: MessageText,
        in block: TimelineTextBlock,
        to limit: Int,
        width: CGFloat,
        style: MessageTextStyle
    ) -> TimelineTextBlock? {
        guard var end = block.endOfLine(limit - 1) else { return nil }
        let string = text.attributed.string as NSString
        let ellipsis: [NSAttributedString.Key: Any] = style.body
        for _ in 0..<12 where end > 0 {
            // Whitespace at the cut would sit between the word and the ellipsis.
            while end > 0, CharacterSet.whitespacesAndNewlines.contains(
                Unicode.Scalar(string.character(at: end - 1)) ?? " "
            ) { end -= 1 }
            // A cut inside a character cluster is a broken character.
            let cut = string.rangeOfComposedCharacterSequence(at: max(0, end - 1))
            let candidate = TimelineTextBlock(
                text: text.truncated(to: NSMaxRange(cut), ellipsis: ellipsis),
                width: width,
                style: style
            )
            if candidate.lineCount <= limit { return candidate }
            end = cut.location
        }
        return nil
    }

    override func layout() {
        super.layout()
        guard text != nil, bounds.width >= 1 else { return }
        let next = layout(width: bounds.width)
        guard next !== block else { return }
        block = next
        fetchMissingImages()
        reconcileFilms()
        needsDisplay = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        requestedImages = []
        fetchMissingImages()
        needsDisplay = true
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { clearSelection() }
    }

    // MARK: Drawing

    private var scale: CGFloat { window?.backingScaleFactor ?? 2 }

    override func draw(_ dirtyRect: NSRect) {
        guard let block, let style, let context = NSGraphicsContext.current?.cgContext else { return }
        TimelineRowPainter.drawTextBlock(
            block,
            at: .zero,
            context: context,
            style: style,
            images: ImageStore.shared,
            scale: scale,
            time: AnimationClock.shared.time,
            state: TimelineRowPainter.TextState(
                revealedSpoilers: revealedSpoilers,
                hoveredPlate: hoveredPlate,
                hoveredSpoiler: hoveredSpoiler,
                layeredEmoji: layeredEmoji,
                hoveredLink: hoveredLink,
                selectedRange: selectedRange,
                plates: plates
            )
        )
    }

    /// **The painter only peeks**, so a picture nobody asks for never arrives.
    private func fetchMissingImages() {
        guard let block else { return }
        for entry in block.emojiRects {
            guard let key = imageKey(for: entry.emoji, side: entry.rect.width),
                  ImageStore.shared.cached(key) == nil,
                  requestedImages.insert(key).inserted
            else { continue }
            Task { [weak self] in
                _ = await ImageStore.shared.image(for: key)
                self?.needsDisplay = true
            }
        }
    }

    /// The same key the painter looks in the store with.
    private func imageKey(for emoji: EmojiRef, side: CGFloat) -> ImageStore.Key? {
        guard let id = emoji.id, let url = CDN.emoji(id: id, animated: emoji.isAnimated, side: side) else {
            return nil
        }
        return ImageStore.Key(url: url, maximumPixelSize: Int((side * scale).rounded(.up)))
    }

    /// One film per animated emoji that may move: not one under a spoiler, since a
    /// layer sits over the painted cover, and none while the prose is told to hold
    /// still.
    private func reconcileFilms() {
        var wanted: [Int: CGRect] = [:]
        if let block, drawing?.plays == true {
            for (index, entry) in block.emojiRects.enumerated() where entry.emoji.isAnimated {
                let center = CGPoint(x: entry.rect.midX, y: entry.rect.midY)
                let isCovered = block.spoilerRects.contains {
                    !revealedSpoilers.contains($0.spoiler) && $0.rect.contains(center)
                }
                if !isCovered { wanted[index] = entry.rect }
            }
        }
        for (index, film) in films where wanted[index] == nil {
            film.tearDown()
            films[index] = nil
            layeredEmoji.remove(index)
        }
        guard let block else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for (index, rect) in wanted {
            if let film = films[index] {
                film.layer.frame = rect
                continue
            }
            guard let key = imageKey(for: block.emojiRects[index].emoji, side: rect.width) else { continue }
            let film = FilmPlayer(key: FilmPlayer.Key(url: key.url, maximumPixelSize: key.maximumPixelSize))
            film.layer.contentsGravity = .resizeAspect
            film.layer.frame = rect
            layer?.addSublayer(film.layer)
            films[index] = film
            film.onPlayback = { [weak self] isPlaying in
                guard let self else { return }
                if isPlaying { self.layeredEmoji.insert(index) } else { self.layeredEmoji.remove(index) }
                self.needsDisplay = true
            }
        }
    }

    // MARK: What's under the pointer

    private func concealedSpoiler(at point: CGPoint) -> Int? {
        block?.spoilerRects.first { $0.rect.contains(point) && !revealedSpoilers.contains($0.spoiler) }?.spoiler
    }

    /// The emoji or link a press here would go to, if something would answer it.
    private func pressable(at point: CGPoint) -> Pressed? {
        guard let block else { return nil }
        if actions.emoji != nil {
            let emoji = block.emojiRects.first { $0.rect.contains(point) }
                ?? block.unicodeEmojiRects.first { $0.rect.contains(point) }
            if let emoji { return .emoji(emoji.emoji, emoji.rect) }
        }
        if actions.follow != nil, let link = block.link(at: point) {
            return .link(link.target, link.rect)
        }
        return nil
    }

    /// **Inside something pressable, only what answers for itself takes the click**,
    /// and the rest goes through to the card.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        guard !selectsText else { return hit }
        let local = convert(point, from: superview)
        return concealedSpoiler(at: local) != nil || pressable(at: local) != nil ? hit : nil
    }

    override func mouseMoved(with event: NSEvent) {
        hover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        hover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        setHover(spoiler: nil, link: nil, plate: nil)
        if NSApp.isActive { NSCursor.arrow.set() }
    }

    private func hover(at point: CGPoint) {
        guard !isDragging else { return }
        let spoiler = concealedSpoiler(at: point)
        let under = spoiler == nil ? pressable(at: point) : nil
        var link: MessageText.LinkTarget?
        if case .link(let target, _) = under { link = target }
        // A plated run answers with its plate, and only one that's a link.
        let plate = link == nil ? nil : block?.plateRects.first {
            $0.rect.contains(point) && block?.text.plates[$0.plate].isInteractive == true
        }?.plate
        setHover(spoiler: spoiler, link: link, plate: plate)
        guard NSApp.isActive else { return }
        if spoiler != nil || under != nil {
            NSCursor.pointingHand.set()
        } else if selectsText {
            NSCursor.iBeam.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    private func setHover(spoiler: Int?, link: MessageText.LinkTarget?, plate: Int?) {
        guard spoiler != hoveredSpoiler || link != hoveredLink || plate != hoveredPlate else { return }
        hoveredSpoiler = spoiler
        hoveredLink = link
        hoveredPlate = plate
        needsDisplay = true
    }

    // MARK: Pressing

    override func mouseDown(with event: NSEvent) {
        press(at: convert(event.locationInWindow, from: nil), clicks: event.clickCount)
    }

    override func mouseDragged(with event: NSEvent) {
        if isDragging { autoscroll(with: event) }
        drag(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        release(at: convert(event.locationInWindow, from: nil))
    }

    /// A press: one click places a selection, two take the word, three the lot.
    func press(at point: CGPoint, clicks: Int) {
        clearSelection()
        guard let block else { return }
        if let spoiler = concealedSpoiler(at: point) {
            revealedSpoilers.insert(spoiler)
            hoveredSpoiler = nil
            reconcileFilms()
            needsDisplay = true
            return
        }
        pressed = clicks == 1 ? pressable(at: point) : nil
        pressOrigin = point
        guard selectsText else { return }
        window?.makeFirstResponder(self)
        let index = block.characterIndex(at: point)
        switch clicks {
        case 2:
            let word = block.wordRange(at: index)
            select(anchor: word.location, focus: NSMaxRange(word))
        case 3...:
            select(anchor: 0, focus: block.text.selectableLength)
        default:
            select(anchor: index, focus: index)
            isDragging = true
        }
    }

    func drag(to point: CGPoint) {
        if hypot(point.x - pressOrigin.x, point.y - pressOrigin.y) > Self.clickSlop { pressed = nil }
        guard isDragging, let block, let current = selection else { return }
        let focus = block.characterIndex(at: point)
        guard focus != current.focus else { return }
        select(anchor: current.anchor, focus: focus)
    }

    func release(at point: CGPoint) {
        isDragging = false
        if let selection, selection.anchor == selection.focus { clearSelection() }
        switch pressed {
        case .emoji(let emoji, let rect):
            actions.emoji?(emoji, rect)
        case .link(let target, let rect):
            actions.follow?(target, anchorInHostingRoot(rect))
        case nil:
            break
        }
        pressed = nil
    }

    // MARK: The selection

    /// The selected characters, in order. Nil with nothing selected.
    var selectedRange: NSRange? {
        guard let selection, selection.anchor != selection.focus else { return nil }
        return NSRange(
            location: min(selection.anchor, selection.focus),
            length: abs(selection.focus - selection.anchor)
        )
    }

    /// The selected words as text, each custom emoji as its `:name:`, as a copy from
    /// a message has them.
    func selectedText() -> String? {
        guard let block, let range = selectedRange else { return nil }
        return TimelineCanvasView.plainText(of: block.text, in: range)
    }

    private func select(anchor: Int, focus: Int) {
        selection = (anchor, focus)
        installClickMonitor()
        needsDisplay = true
    }

    private func clearSelection() {
        removeClickMonitor()
        guard selection != nil else { return }
        selection = nil
        isDragging = false
        needsDisplay = true
    }

    override func resignFirstResponder() -> Bool {
        clearSelection()
        return super.resignFirstResponder()
    }

    private func installClickMonitor() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            let point = self.convert(event.locationInWindow, from: nil)
            if event.window !== self.window || !self.bounds.contains(point) {
                self.clearSelection()
            }
            return event
        }
    }

    private func removeClickMonitor() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    // MARK: Commands

    @objc func copy(_ sender: Any?) {
        guard let text = selectedText(), !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    override func selectAll(_ sender: Any?) {
        guard let block else { return }
        select(anchor: 0, focus: block.text.selectableLength)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)), #selector(lookUp(_:)): selectedRange != nil
        default: true
        }
    }

    /// The system's menu at the pointer. **A right-click off the selection takes the
    /// word under it**, as it does in any Mac text, so Copy is never greyed out over
    /// the words someone is pointing at.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let block else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let link = block.link(at: point)
        var items: [NSMenuItem] = []
        if case .url(let url)? = link?.target {
            items.append(item("Copy Link", #selector(copyLink(_:)), represented: url))
        }
        if selectsText, concealedSpoiler(at: point) == nil {
            window?.makeFirstResponder(self)
            let index = block.characterIndex(at: point)
            if selectedRange.map({ !NSLocationInRange(index, $0) }) ?? true {
                let word = block.wordRange(at: index)
                select(anchor: word.location, focus: NSMaxRange(word))
            }
            items.append(item("Copy", #selector(copy(_:))))
            if let words = selectedText()?.trimmingCharacters(in: .whitespacesAndNewlines), !words.isEmpty {
                let shown = words.count > 24 ? words.prefix(24) + "\u{2026}" : Substring(words)
                items.append(item("Look Up \u{201C}\(shown)\u{201D}", #selector(lookUp(_:))))
            }
            items.append(.separator())
            items.append(item("Select All", #selector(selectAll(_:))))
        }
        guard !items.isEmpty else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = true
        items.forEach(menu.addItem)
        return menu
    }

    private func item(_ title: String, _ action: Selector, represented: Any? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = represented
        return item
    }

    @objc private func copyLink(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    /// macOS's Look Up over the selected words, lit where they're drawn.
    @objc private func lookUp(_ sender: Any?) {
        guard let block, let range = selectedRange,
              let baseline = block.baselineOrigin(at: range.location)
        else { return }
        showDefinition(for: block.text.attributed.attributedSubstring(from: range), at: baseline)
    }

    // MARK: Testing

    /// Whether a spoiler has been lifted. For the tests, which have no pixels to ask.
    func isRevealed(_ spoiler: Int) -> Bool { revealedSpoilers.contains(spoiler) }

    /// The layout at the current bounds, laid out now. For the tests.
    func layoutForTesting() -> TimelineTextBlock? {
        layoutSubtreeIfNeeded()
        return block
    }
}
