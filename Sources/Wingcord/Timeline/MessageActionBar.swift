import SwiftUI
import WingcordCore

/// The pill that appears at a message's trailing edge while the pointer rests
/// on it.
///
/// **Composed, not drawn, and it is the one thing over the transcript that
/// is.** The rows are painted because there are hundreds of them; this is one
/// surface at a time, it is glass, and Core Graphics cannot draw glass. What it
/// costs is a handful of nodes that exist only while somebody is pointing at a
/// row.
///
/// It is `.clear` glass, not `.regular`: what passes under it is avatars, emoji
/// and somebody's message — content — and `.regular` frosts all of that into a
/// grey slab. `INVARIANTS.md` §4.
///
/// **One glass body with regions inside it**, never a glass button each: a
/// cluster of nine glass capsules over a scrolling transcript is nine sampled
/// blurs, and §4 forbids stacking them anyway.
struct MessageActionBar: View {
    var items: [MessageActionKind]
    var perform: (MessageActionKind) -> Void

    @Environment(\.motion) private var motion
    /// Which glyph the pointer is on. One piece of state for the whole row —
    /// a `@State` per button would be a view per button that invalidates
    /// independently.
    @State private var hovered: MessageActionKind?

    /// Shared with the overlay, which solves a button's box from them rather
    /// than measuring it — see `MessageActionBarOverlay.anchor(of:in:)`.
    /// **Generous, because the pill is chrome the pointer aims at.** Twenty-four
    /// points with a one-point gap put five targets inside a hundred and
    /// twenty-five, which is a row of glyphs rather than a row of controls — and
    /// a lensing material has nothing to lens through at that scale.
    static let glyphSide: CGFloat = 28
    static let gap: CGFloat = 2
    static let padding: CGFloat = 4

    /// The pill's width for `count` glyphs — solved, as a button's box is.
    static func width(for count: Int) -> CGFloat {
        CGFloat(count) * glyphSide + CGFloat(max(0, count - 1)) * gap + padding * 2
    }

    var body: some View {
        HStack(spacing: Self.gap) {
            ForEach(items) { kind in
                Button { perform(kind) } label: {
                    Image(symbol: kind.symbolName)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(tint(of: kind))
                        .frame(width: Self.glyphSide, height: Self.glyphSide)
                        .background {
                            // A region inside the pill's own material, not a
                            // second material — §4 rule 2.
                            if hovered == kind {
                                Circle().fill(Palette.hoverFill)
                            }
                        }
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .onHover { isInside in
                    // A `@State` write of an equal value still invalidates, and
                    // a pointer crossing a 24-point target generates these at
                    // event rate.
                    let next = isInside ? kind : (hovered == kind ? nil : hovered)
                    guard next != hovered else { return }
                    hovered = next
                }
                .help(kind.title)
                .accessibilityLabel(Text(kind.title))
            }
        }
        .padding(Self.padding)
        .frame(height: TimelineMetrics.actionBarHeight)
        // **`.interactive()`, and this is the one hover surface that has earned
        // it.** §4's rule against interactive glass is about a row in a
        // *scrolling list*: the cursor stands still while the row slides under
        // it, so the displacement is recomputed every frame and the row wobbles.
        // This pill does not scroll — it is repositioned to whichever row the
        // pointer is on, and the pointer is by definition resting on it. Without
        // it the material has no specular response at all and reads as a flat
        // tinted capsule rather than as glass.
        //
        // **`.regular`, untinted**: the HIG's default for a control over
        // content, which frosts the row behind enough to read the glyphs
        // without a hand-drawn rim.
        .glassEffect(.regular.interactive(), in: .capsule)
        // The hover fill is the only thing that moves here, and it is a fill —
        // a spring would describe physics that are not happening.
        .animation(motion.fadeQuick, value: hovered)
    }

    private func tint(of kind: MessageActionKind) -> AnyShapeStyle {
        if kind.isDestructive, hovered == kind {
            return AnyShapeStyle(Palette.destructive)
        }
        return AnyShapeStyle(hovered == kind ? Ink.primary : Ink.secondary)
    }
}

/// Places the pill over the transcript, and decides which one is shown.
///
/// **Overlaid on the scroll view rather than drawn into the canvas.** The rect
/// it is placed at comes from the canvas in the clip view's own space — see
/// `TimelineCanvasView.publishHover` — so it travels with the viewport and never
/// has to know how far down the transcript the row actually is.
struct MessageActionBarOverlay: View {
    var channelID: ChannelID

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    /// Whether Shift is down, which swaps the pill's contents for the direct
    /// actions. Read through the modifier-keys API rather than a local event
    /// monitor: a monitor here is an object that outlives the view unless it is
    /// removed by hand, for a value SwiftUI already publishes.
    @State private var isShifted = false
    /// Whether the pointer is on the pill itself.
    ///
    /// **The pill is a sibling view above the canvas**, so a pointer reaching it
    /// may or may not leave the canvas's tracking area depending on how AppKit
    /// resolves the overlap. Holding the last hover while the pill is under the
    /// pointer makes the answer the same either way.
    @State private var isPointerOnBar = false
    @State private var held: MessageHover?
    /// Where this overlay starts, in the SwiftUI root's space.
    ///
    /// **Recorded rather than measured per click.** Every surface the pill
    /// raises anchors in the root — one titlebar and one sidebar away from here
    /// — and `onGeometryChange` reads the value the layout already computed,
    /// firing only when the pane actually moves.
    @State private var originInRoot: CGPoint = .zero

    var body: some View {
        // Read first, so the dependency is registered whether or not there is a
        // hover to draw. A memo that returns early registers nothing.
        let hover = model.messageHover
        let _ = model.roleRevision
        let _ = model.messageContentRevision
        let _ = model.inboundMessageRevision
        let current = hover ?? (isPointerOnBar ? held : nil)
        let actions = current.map { model.actions(for: $0.messageID, in: channelID) } ?? []
        let items = actions.isEmpty ? [] : actions.barItems(shifted: isShifted)

        // **A `GeometryReader`, because it is the one container that fills its
        // proposal and lays its child out at the top-leading corner.** A
        // `ZStack` with one child sizes to that child, so the pill would be
        // placed relative to itself — which is a pill drawn at the top-left of
        // the transcript, or not visibly drawn at all.
        return GeometryReader { _ in
            if let current, !items.isEmpty {
                let bar = MessageActionBar(items: items) { kind in
                    perform(kind, on: current.messageID, items: items)
                }
                .fixedSize()
                .onHover { isPointerOnBar = $0 }
                if let anchor = current.pillAnchor, let leading = bubbleLeading(of: current, items: items) {
                    // Beside a bubble, level with its first line, growing out
                    // of the side it hangs from.
                    bar
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .offset(x: leading, y: anchor.midY - TimelineMetrics.actionBarHeight / 2)
                        .transition(.materialize(from: anchor.edge == .trailing ? .trailing : .leading))
                } else {
                    // **Right-aligned by a frame, not by arithmetic over a
                    // measured width.** `maxWidth: .infinity` with a trailing
                    // alignment puts the pill against the transcript's own
                    // margin without anything having to know how wide it is —
                    // and an empty frame hit-tests nothing, so the transcript
                    // underneath still answers the pointer everywhere the pill
                    // is not.
                    bar
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.trailing, TimelineMetrics.actionBarTrailingInset)
                        .offset(y: current.rowFrame.minY - TimelineMetrics.actionBarRise)
                        .transition(.materialize(from: .trailing))
                }
            }
        }
        .animation(motion.hover, value: current?.messageID)
        .onModifierKeysChanged(mask: .shift) { _, modifiers in
            let shifted = modifiers.contains(.shift)
            guard shifted != isShifted else { return }
            isShifted = shifted
        }
        .onChange(of: hover) { _, newValue in
            // Kept only while it exists, so a pointer released onto the pill has
            // something to keep showing.
            if let newValue { held = newValue }
        }
        .onGeometryChange(for: CGPoint.self) { proxy in
            proxy.frame(in: .global).origin
        } action: { origin in
            let resolved = CGPoint(
                x: origin.x - PresentationOrigin.value.x,
                y: origin.y - PresentationOrigin.value.y
            )
            guard resolved != originInRoot else { return }
            originInRoot = resolved
        }
    }

    private func perform(
        _ kind: MessageActionKind,
        on messageID: MessageID,
        items: [MessageActionKind]
    ) {
        MessageActionRouter.perform(
            kind,
            messageID: messageID,
            channelID: channelID,
            model: model,
            anchor: anchor(of: kind, in: items)
        )
    }

    /// Where a surface raised from one of the pill's buttons grows out of.
    ///
    /// **Solved, not measured.** The pill is right-aligned and every glyph is
    /// the same width, so a button's box is arithmetic from its position in the
    /// row — and arithmetic cannot go stale between the layout that placed it
    /// and the click that reads it, which a stored measurement can.
    private func anchor(of kind: MessageActionKind, in items: [MessageActionKind]) -> CGRect {
        guard let hover = model.messageHover ?? held,
              let index = items.firstIndex(of: kind)
        else { return .zero }
        let stride = MessageActionBar.glyphSide + MessageActionBar.gap
        let leading = bubbleLeading(of: hover, items: items)
            ?? hover.rowFrame.maxX - TimelineMetrics.actionBarTrailingInset
                - MessageActionBar.width(for: items.count)
        let top = hover.pillAnchor.map { $0.midY - TimelineMetrics.actionBarHeight / 2 }
            ?? hover.rowFrame.minY - TimelineMetrics.actionBarRise
        return CGRect(
            x: originInRoot.x + leading + MessageActionBar.padding + CGFloat(index) * stride,
            y: originInRoot.y + top + MessageActionBar.padding,
            width: MessageActionBar.glyphSide,
            height: MessageActionBar.glyphSide
        )
    }

    /// The pill's leading edge beside a bubble, kept inside the transcript's
    /// margins — on a narrow window it would rather sit over a bubble's
    /// corner than hang off the edge. Nil over the row's trailing end.
    ///
    /// The row's trailing edge *is* the transcript's: the canvas lays every
    /// row out to its full width.
    private func bubbleLeading(of hover: MessageHover, items: [MessageActionKind]) -> CGFloat? {
        guard let anchor = hover.pillAnchor else { return nil }
        let width = MessageActionBar.width(for: items.count)
        let inset = TimelineMetrics.actionBarTrailingInset
        let x = anchor.edge == .trailing ? anchor.x - width : anchor.x
        return min(max(x, hover.rowFrame.minX + inset), hover.rowFrame.maxX - inset - width)
    }
}
