import SwiftUI

/// Its content at its own width, or at `max` where that is narrower — and
/// measured at the width it is drawn at.
///
/// **What `.frame(maxWidth:)` does not do under `.fixedSize()`.** Asked for its
/// ideal size, the frame asks its content for *its* ideal size — a sentence on
/// one line — narrows the width to the cap and keeps the one line's height. The
/// sentence is then drawn at the cap, wraps, and runs out of whatever was sized
/// for it: a tooltip's words out of its glass. This asks the content again at
/// the capped width, so the height is the wrapped one.
struct CappedWidth: Layout {
    var max: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        return content.sizeThatFits(ProposedViewSize(width: width(of: content, in: proposal), height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let content = subviews.first else { return }
        content.place(
            at: bounds.origin,
            proposal: ProposedViewSize(width: width(of: content, in: proposal), height: nil)
        )
    }

    /// The content's own width, the cap, or what the parent offered — the
    /// least of them.
    private func width(of content: LayoutSubview, in proposal: ProposedViewSize) -> CGFloat {
        let ideal = content.sizeThatFits(.unspecified).width
        return min(ideal, max, proposal.width ?? .infinity)
    }
}
