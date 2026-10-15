import AppKit
import SwiftUI

/// A text field that writes markdown the way Discord's box does: the markers
/// stay visible and styled as they are typed, and selecting text brings up a
/// formatting toolbar over it.
///
/// **One component for every place somebody writes something Discord will
/// render** — the composer, both bios and a forum post's body — so the four
/// cannot drift into four different ideas of what `**` does while typing.
///
/// Plain text underneath, always: what is typed is what is sent, and the
/// styling is a reading of it rather than a second copy of it.
struct MarkdownEditor: View {
    @Binding var text: String
    @Binding var isFocused: Bool
    var placeholder: String
    var font: NSFont
    /// The text's colour where it must not be the room's usual one — the
    /// composer floats over the moving transcript and writes in `InkColor.solid`.
    var ink: NSColor?
    var lines: ClosedRange<Int>
    /// Where typing stops — a bio's 190.
    var characterLimit: Int?
    /// Whether Return sends, as it does in the composer, rather than starting
    /// a new line. Shift-Return is always a new line.
    var returnSubmits = false
    /// The owner's say over a key before the text gets it. `true` means it was
    /// handled and the text never sees it.
    var onKey: ((EditorKey) -> Bool)?
    var onSubmit: (() -> Void)?
    /// Files pasted into the field — copied in the Finder, or an image on the
    /// clipboard — answered with whether they were taken. Nil where the field
    /// takes text only. See `PastedFiles`.
    var onPasteFiles: (([URL]) -> Bool)?
    /// Whether this is the chat input — whose right-click menu carries what
    /// Discord's `textarea-context` menu does, such as Silent Typing's
    /// checkbox — rather than some other markdown field.
    var isChatInput = false
    /// How each mention token is drawn — nil leaves tokens as text, which is
    /// right for a field whose text is not a message.
    var chips: ((EditorMention) -> EditorChip?)?
    /// Moves when anything a chip names may have changed — a name arriving, a
    /// role renamed — so the chips are drawn again without a keystroke.
    var chipRevision: UInt64 = 0
    /// Told where the field is, for an owner that needs to know where the
    /// words were when it acted on them — see `EditorAnchor`.
    var anchor: EditorAnchor?

    @State private var height: CGFloat?

    var body: some View {
        MarkdownEditorRepresentable(
            text: $text,
            isFocused: $isFocused,
            placeholder: placeholder,
            font: font,
            ink: ink,
            lines: lines,
            characterLimit: characterLimit,
            returnSubmits: returnSubmits,
            onKey: onKey,
            onSubmit: onSubmit,
            onPasteFiles: onPasteFiles,
            isChatInput: isChatInput,
            chips: chips,
            chipRevision: chipRevision,
            anchor: anchor,
            onHeightChange: { measured in
                if height != measured { height = measured }
            }
        )
        .frame(height: height ?? lineHeight * CGFloat(lines.lowerBound))
    }

    private var lineHeight: CGFloat { ceil(font.ascender - font.descender + font.leading) }
}

private struct MarkdownEditorRepresentable: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var placeholder: String
    var font: NSFont
    var ink: NSColor?
    var lines: ClosedRange<Int>
    var characterLimit: Int?
    var returnSubmits: Bool
    var onKey: ((EditorKey) -> Bool)?
    var onSubmit: (() -> Void)?
    var onPasteFiles: (([URL]) -> Bool)?
    var isChatInput: Bool
    var chips: ((EditorMention) -> EditorChip?)?
    var chipRevision: UInt64
    var anchor: EditorAnchor?
    var onHeightChange: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(owner: self) }

    func makeNSView(context: Context) -> MarkdownEditorContainer {
        let container = MarkdownEditorContainer()
        let textView = container.textView
        textView.delegate = context.coordinator
        textView.font = font
        textView.string = text
        container.lines = lines
        context.coordinator.attach(container)
        anchor?.container = container
        return container
    }

    func updateNSView(_ container: MarkdownEditorContainer, context: Context) {
        let coordinator = context.coordinator
        coordinator.owner = self
        let textView = container.textView
        container.onHeightChange = onHeightChange
        container.lines = lines
        // Refreshed rather than captured once: it closes over the channel the
        // composer is on now.
        textView.onPasteFiles = onPasteFiles
        textView.isChatInput = isChatInput

        var needsStyle = false
        if textView.font != font {
            textView.font = font
            needsStyle = true
        }
        if textView.string != text {
            textView.string = text
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            needsStyle = true
        }
        if coordinator.chipRevision != chipRevision {
            coordinator.chipRevision = chipRevision
            needsStyle = true
        }
        if needsStyle { coordinator.restyle() }
        coordinator.updatePlaceholder()

        // Focus, asked for from outside — the composer taking the caret when a
        // conversation opens. Deferred, because becoming first responder
        // reports back into this same binding.
        let isFirstResponder = textView.window?.firstResponder === textView
        if isFocused != isFirstResponder {
            DispatchQueue.main.async { [weak textView] in
                guard let textView, let window = textView.window else { return }
                if isFocused, window.firstResponder !== textView {
                    window.makeFirstResponder(textView)
                } else if !isFocused, window.firstResponder === textView {
                    window.makeFirstResponder(nil)
                }
            }
        }
    }

    static func dismantleNSView(_ container: MarkdownEditorContainer, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var owner: MarkdownEditorRepresentable
        private weak var container: MarkdownEditorContainer?
        private let toolbar = SelectionToolbarController()
        private var toolbarTask: Task<Void, Never>?
        /// A toolbar button is rewriting the text; the rewrite must not take the
        /// toolbar down the way typing does.
        private var isApplyingFormat = false
        /// The chips' tokens, which the caret and a delete treat as one
        /// character each — see `EditorMentionAtoms`.
        private var atoms: [NSRange] = []
        var chipRevision: UInt64 = 0

        init(owner: MarkdownEditorRepresentable) {
            self.owner = owner
        }

        func attach(_ container: MarkdownEditorContainer) {
            self.container = container
            let textView = container.textView
            textView.onFocusChange = { [weak self] focused in
                guard let self else { return }
                if !focused { hideToolbar() }
                let binding = owner.$isFocused
                // Never inside a view update: this can be reached from one.
                DispatchQueue.main.async {
                    if binding.wrappedValue != focused { binding.wrappedValue = focused }
                }
            }
            textView.onSelectionSettled = { [weak self] in self?.selectionSettled() }
            textView.onFormatShortcut = { [weak self] format in self?.toggle(format) }
            textView.onFormatCommand = { [weak self] action in self?.perform(action) }
            restyle()
            updatePlaceholder()
            container.onHeightChange = owner.onHeightChange
            container.remeasure()
        }

        func detach() {
            hideToolbar()
            container?.textView.delegate = nil
            container = nil
        }

        func restyle() {
            guard let textView = container?.textView, let storage = textView.textStorage else { return }
            let styler = MarkdownStyler.current(font: owner.font, ink: owner.ink)
            let placements = styler.apply(to: storage, chips: owner.chips)
            textView.typingAttributes = styler.baseAttributes
            textView.chips = placements
            atoms = placements.map(\.range)
        }

        func updatePlaceholder() {
            guard let textView = container?.textView else { return }
            let current = textView.placeholder?.string
            guard current != owner.placeholder else { return }
            textView.placeholder = NSAttributedString(string: owner.placeholder, attributes: [
                .font: owner.font,
                .foregroundColor: owner.ink?.withAlphaComponent(0.5) ?? NSColor.placeholderTextColor,
            ])
        }

        // MARK: NSTextViewDelegate

        func textDidChange(_ notification: Notification) {
            guard let textView = container?.textView else { return }
            if let limit = owner.characterLimit, textView.string.count > limit {
                let kept = String(textView.string.prefix(limit))
                textView.string = kept
            }
            restyle()
            if owner.text != textView.string { owner.text = textView.string }
            container?.remeasure()
            if !isApplyingFormat { hideToolbar() }
        }

        /// A caret never rests inside a chip, and a selection takes all of one.
        func textView(
            _ textView: NSTextView,
            willChangeSelectionFromCharacterRange oldRange: NSRange,
            toCharacterRange newRange: NSRange
        ) -> NSRange {
            EditorMentionAtoms.snap(newRange, from: oldRange, around: atoms)
        }

        /// An edit that reaches into a chip takes the whole of it — a delete
        /// after a mention removes the mention, as Discord's box does.
        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn range: NSRange,
            replacementString: String?
        ) -> Bool {
            let whole = EditorMentionAtoms.expand(range, around: atoms)
            guard whole != range else { return true }
            textView.insertText(replacementString ?? "", replacementRange: whole)
            return false
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let key: EditorKey? = switch selector {
            case #selector(NSResponder.moveUp(_:)): .up
            case #selector(NSResponder.moveDown(_:)): .down
            case #selector(NSResponder.insertTab(_:)): .tab
            case #selector(NSResponder.deleteBackward(_:)): .backspace
            case #selector(NSResponder.cancelOperation(_:)): .escape
            case #selector(NSResponder.insertNewline(_:)):
                .return(shift: NSApp.currentEvent?.modifierFlags.contains(.shift) == true)
            default: nil
            }
            guard let key else { return false }
            if key == .escape, toolbar.isShown {
                hideToolbar()
                return true
            }
            if owner.onKey?(key) == true { return true }
            switch key {
            case .return(let shift):
                guard owner.returnSubmits, !shift else { return false }
                owner.onSubmit?()
                return true
            case .tab:
                // A field, not a document: Tab leaves it, as it leaves a text
                // field, rather than typing a tab nobody's message can show.
                textView.window?.selectNextKeyView(nil)
                return true
            case .up, .down, .backspace, .escape:
                return false
            }
        }

        // MARK: The toolbar

        private func selectionSettled() {
            toolbarTask?.cancel()
            guard let textView = container?.textView,
                  textView.window?.firstResponder === textView,
                  textView.selectedRange().length > 0
            else {
                hideToolbar()
                return
            }
            // Discord's beat before it appears, so a click-and-drag that is
            // still deciding does not flash a bar at every stop.
            toolbarTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                self?.showToolbar()
            }
        }

        private func showToolbar() {
            guard let textView = container?.textView else { return }
            let selection = textView.selectedRange()
            guard selection.length > 0 else { return }
            toolbar.show(
                over: textView,
                active: FormattingToggle.activeFormats(in: textView.string, selection: selection),
                act: { [weak self] action in
                    switch action {
                    case .format(let format): self?.toggle(format)
                    case .quote: self?.toggleQuote()
                    }
                }
            )
        }

        private func hideToolbar() {
            toolbarTask?.cancel()
            toolbarTask = nil
            toolbar.hide()
        }

        private func toggle(_ format: MarkdownFormat) {
            guard let textView = container?.textView else { return }
            apply(FormattingToggle.toggle(format, in: textView.string, selection: textView.selectedRange()))
        }

        private func toggleQuote() {
            guard let textView = container?.textView else { return }
            apply(FormattingToggle.toggleQuote(in: textView.string, selection: textView.selectedRange()))
        }

        /// The menu bar's Format menu, on this field.
        private func perform(_ action: ComposerFormatCommand.Action) {
            guard let textView = container?.textView else { return }
            let text = textView.string
            let selection = textView.selectedRange()
            switch action {
            case .format(let format): toggle(format)
            case .quote: toggleQuote()
            case .codeBlock:
                apply(FormattingToggle.toggleCodeBlock(in: text, selection: selection))
            case .linePrefix(let prefix):
                apply(FormattingToggle.toggleLinePrefix(prefix, in: text, selection: selection))
            case .insert(let words):
                // Through the field's own typing path, so the mention list and
                // the time picker hear it exactly as if it had been typed.
                textView.insertText(words, replacementRange: selection)
            case .send:
                owner.onSubmit?()
            }
        }

        /// Replaces the text through the text view's own editing path, so the
        /// change is one undo step and the owner hears about it once.
        private func apply(_ edit: FormattingEdit) {
            guard let textView = container?.textView else { return }
            let whole = NSRange(location: 0, length: (textView.string as NSString).length)
            guard textView.shouldChangeText(in: whole, replacementString: edit.text) else { return }
            isApplyingFormat = true
            textView.textStorage?.replaceCharacters(in: whole, with: edit.text)
            textView.didChangeText()
            textView.setSelectedRange(edit.selection)
            isApplyingFormat = false
            if edit.selection.length > 0 { showToolbar() } else { hideToolbar() }
        }
    }
}

extension NSColor {
    /// `InkColor.solid` for AppKit: white in a dark room, black in a light
    /// one, resolved by the appearance it is drawn in.
    static let composerSolid = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .white : .black
    }
}
