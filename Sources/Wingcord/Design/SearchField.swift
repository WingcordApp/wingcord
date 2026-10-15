import AppKit
import SwiftUI

/// The system's search field on Liquid Glass: the capsule a toolbar's search
/// item is, for a page in this window, which has no toolbar to put one in.
///
/// **`NSSearchField`, not a `TextField`**, for `SegmentedPicker`'s reason: the
/// rounded-border text field is the box from before Liquid Glass, and the
/// search field brings the magnifier, the clear button and the system's own
/// editing and keyboard story with it.
///
/// **Its own bezel off, the system's glass under it.** Outside a toolbar the
/// field draws an opaque text-field fill — a dark slab over the wallpaper,
/// measured at every control size — and the glass capsule is the toolbar
/// item's, not the field's. So the field draws only its text and its two
/// buttons, and sits in `.glassEffect` exactly as the toolbar seats it; one
/// material, never two (`INVARIANTS.md` §4 rule 2).
struct SearchField: View {
    var prompt: String = "Search"
    @Binding var text: String

    /// The toolbar search item's height, and the segmented strip's.
    static var height: CGFloat { SegmentedPicker<Int>.stripHeight }

    var body: some View {
        SearchFieldControl(prompt: prompt, text: $text)
            .controlSize(.large)
            .padding(.horizontal, 12)
            .frame(height: Self.height)
            .glassEffect(.regular.interactive(), in: .capsule)
    }
}

private struct SearchFieldControl: NSViewRepresentable {
    var prompt: String
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = GlassSearchField()
        field.placeholderString = prompt
        // The glass is the capsule; the field draws no slab of its own.
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = context.coordinator
        // Every keystroke filters, as a list's search does; Return adds nothing.
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.target = context.coordinator
        field.action = #selector(Coordinator.searchDidChange(_:))
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    /// The field's own height for its font, so the capsule centres it.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSearchField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.intrinsicContentSize.width, height: nsView.intrinsicContentSize.height)
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        // Rebound every update, as `SegmentedPicker`'s coordinator is.
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }
        if field.placeholderString != prompt { field.placeholderString = prompt }
    }

    /// The field without its bezel, editing where it draws.
    ///
    /// **A bezel-less search field puts its editor at the bezel's text rect**,
    /// which does not leave room for the magnifier: the placeholder drew past
    /// the glass's icon and the typed text over it (measured). The cell below
    /// edits and selects in `searchTextRect`, where the placeholder already is.
    final class GlassSearchField: NSSearchField {
        override class var cellClass: AnyClass? {
            get { GlassSearchFieldCell.self }
            set {}
        }
    }

    final class GlassSearchFieldCell: NSSearchFieldCell {
        override func edit(
            withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText,
            delegate: Any?, event: NSEvent?
        ) {
            super.edit(
                withFrame: searchTextRect(forBounds: rect), in: controlView, editor: textObj,
                delegate: delegate, event: event
            )
        }

        override func select(
            withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText,
            delegate: Any?, start selStart: Int, length selLength: Int
        ) {
            super.select(
                withFrame: searchTextRect(forBounds: rect), in: controlView, editor: textObj,
                delegate: delegate, start: selStart, length: selLength
            )
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        @objc func searchDidChange(_ sender: NSSearchField) {
            write(sender.stringValue)
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            write(field.stringValue)
        }

        private func write(_ value: String) {
            // Guarded: an equal write still invalidates everything reading it.
            guard text.wrappedValue != value else { return }
            text.wrappedValue = value
        }
    }
}
