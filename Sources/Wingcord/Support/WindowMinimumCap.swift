import SwiftUI

/// Caps what the window root reports as its minimum size.
///
/// **A view must never be able to grow the window.** SwiftUI hands a hosted
/// view's minimum size to the window's `contentMinSize`, and AppKit *grows* the
/// window to satisfy it — under the Dock, behind the menu bar, unrecoverable by
/// dragging. Worse, SwiftUI re-derives that minimum from inside the window's own
/// layout pass and writes it back, so clamping the frame afterwards is a second
/// writer that cannot converge: the clamp shrinks, nothing lowers the demand,
/// the next pass grows it again, and AppKit aborts once the constraint passes
/// outnumber the views in the window.
///
/// This removes the demand at its source instead of fighting it downstream. It
/// answers SwiftUI's minimum probe — `sizeThatFits` under `ProposedViewSize.zero`
/// — with a constant, **ignoring the subtree entirely**. Every definite proposal
/// is answered with exactly the proposal, so the root can never report more than
/// it was offered; `.infinity` passes through, so there is still no maximum.
///
/// A `Layout` and not a `.frame`: a modifier can RAISE a child's reported
/// minimum and can never lower it, so only a container that computes its own
/// reported size can cap one.
///
/// It is inert until some view demands more room. **Do not remove it because the
/// window looks fine** — that is what it is for, and the failure it prevents is
/// one that arrives with whatever view is added next.
struct WindowMinimumCap: Layout {
    var minimumWidth: CGFloat
    var minimumHeight: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        // The minimum probe: answer flatly, without measuring anything.
        if proposal == .zero {
            return CGSize(width: minimumWidth, height: minimumHeight)
        }

        // A definite proposal is answered with itself. The measurement below is
        // only for axes the proposal left unspecified.
        //
        // Note this DOES measure the child in that case, and that is deliberate:
        // returning the proposal before measuring is functionally identical but
        // measurably worse, because SwiftUI caches the child's size from the
        // measure and the placement pass reuses it. Skipping the measure only
        // defers the same layout into `placeSubviews`, which gets no such reuse.
        // A discarded return value is not the same thing as discarded work.
        let measured = subviews.first?.sizeThatFits(proposal) ?? .zero
        return CGSize(
            width: proposal.width ?? measured.width,
            height: proposal.height ?? measured.height
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        for subview in subviews {
            subview.place(
                at: bounds.origin,
                proposal: ProposedViewSize(bounds.size)
            )
        }
    }
}

extension View {
    /// Apply once, at the window root, and nowhere else.
    func capsWindowMinimumSize(
        width: CGFloat = Proportions.windowMinWidth,
        height: CGFloat = Proportions.windowMinHeight
    ) -> some View {
        WindowMinimumCap(minimumWidth: width, minimumHeight: height) {
            self
        }
    }
}
