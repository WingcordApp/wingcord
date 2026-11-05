import AppKit

/// Where an editor's words are on screen, for the owner that acts on them —
/// the composer, sending them.
///
/// **Read at the moment it is asked, never stored.** A rect kept from a layout
/// pass outlives the layout it measured (§2's rule against a measurement
/// written into state); this asks the text view itself, the instant a send
/// needs the answer.
@MainActor
final class EditorAnchor {
    /// Set once, by the editor that owns the field.
    weak var container: MarkdownEditorContainer?

    /// Where a voice note leaves from: the field around it, whatever's typed there, with
    /// its middle on the line the bars were on. The words aren't what's flying.
    func voiceNoteLaunch(fieldPadding: CGFloat) -> SendLaunch? {
        guard let container, container.window != nil else { return nil }
        let field = container.convert(container.bounds, to: nil).insetBy(dx: 0, dy: -fieldPadding)
        return SendLaunch(
            firstBaseline: CGPoint(x: field.minX, y: field.midY),
            field: field,
            fontSize: 0,
            isOneLine: true
        )
    }

    /// The words' first line and the field around them, in window space.
    ///
    /// - Parameter fieldPadding: the air the owner keeps around the field, so
    ///   the bubble opens out of the plate the reader sees rather than out of
    ///   the text view's own tighter box.
    func launch(fieldPadding: CGFloat) -> SendLaunch? {
        guard let container, container.window != nil,
              let manager = container.textView.textLayoutManager,
              let font = container.textView.font
        else { return nil }
        let textView = container.textView

        // The first line fragment: its leading edge, and its baseline — the
        // glyph origin is measured from the top of the line's own bounds.
        var firstLine: CGPoint?
        manager.enumerateTextLayoutFragments(from: manager.documentRange.location, options: [.ensuresLayout]) { fragment in
            if let line = fragment.textLineFragments.first {
                let frame = fragment.layoutFragmentFrame
                firstLine = CGPoint(
                    x: frame.minX + line.typographicBounds.minX + line.glyphOrigin.x,
                    y: frame.minY + line.typographicBounds.minY + line.glyphOrigin.y
                )
            }
            return false
        }
        guard let firstLine else { return nil }

        let inset = textView.textContainerOrigin
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        // A field scrolled past its first line launches from its top, which
        // is where the words visibly leave from.
        let visible = textView.visibleRect
        let baseline = CGPoint(
            x: inset.x + firstLine.x,
            y: max(inset.y + firstLine.y, visible.minY + font.ascender)
        )
        return SendLaunch(
            firstBaseline: textView.convert(baseline, to: nil),
            field: container.convert(container.bounds, to: nil).insetBy(dx: 0, dy: -fieldPadding),
            fontSize: font.pointSize,
            isOneLine: manager.usageBoundsForTextContainer.height <= lineHeight * 1.5
        )
    }
}
