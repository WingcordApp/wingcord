import SwiftUI
import WingcordCore

/// Draws a profile frame on a card.
///
/// **The whole view is a negative padding, and that is the trick.** A frame's
/// artwork belongs *outside* the card, but nothing here knows how tall the card
/// is — its height is its content's, which is a bio and a role flow that arrive
/// over the network. Asking for it means a `GeometryReader` writing a
/// measurement into `@State`, which costs an extra layout pass, invalidates
/// everything downstream of that state, and — the part that actually bites — a
/// value that outlives the thing it measured.
///
/// So the height is never asked for. Applied as an `.overlay`, this view is
/// proposed the card's own size; the negative padding hands the stack inside it
/// that proposal *plus* each overflow, and reports the card's size back
/// unchanged. The stack is therefore the card grown by exactly the four numbers
/// the payload sent, on every card, with no measurement anywhere:
///
/// ```
///  ┌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌┐  ← the stack: card ⊕ overflow
///  ╎ ┌──────────────────┐ ╎
///  ╎ │ the card         │ ╎  ← what the overlay was proposed
///  ╎ └──────────────────┘ ╎
///  └╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌┘
/// ```
///
/// Each layer then pins itself to the edge its `anchor` names and takes its own
/// aspect from the artwork, so a top garland hangs off the top and a bottom one
/// off the foot however tall the card turned out to be.
///
/// **Never a glass element and never inside a `GlassEffectContainer`.** A
/// container promotes its glass above ordinary siblings and renders it itself —
/// §4 rule 4 — so a frame joined to one would draw over the card's own controls
/// instead of around them.
/// Sizes one layer according to the edge it hangs from.
///
/// A branch is safe here where it usually is not: a layer's anchor comes from
/// the payload and cannot change while the frame is on screen, so the two arms
/// are never swapped for the same `id` and no image is ever torn down.
private struct FrameLayerFit: ViewModifier {
    var anchor: ProfileFrame.Anchor
    var layout: ProfileFrameLayout

    @ViewBuilder
    func body(content: Content) -> some View {
        if anchor == .center {
            // **No aspect, and the card's height rather than the
            // composition's.** A border's artwork is authored uniform along y
            // precisely so it can be pulled to fit, and the height nothing here
            // knows is the card's — but the stack it is stretched inside has
            // already been grown by the two overflows, so filling that stack
            // ran the rails up past the artwork meant to cap them. Measured on
            // Kawaii Cat (`overflow_top: 304`, `overflow_bottom: 135` against
            // an `inner_width` of 1200): two bare pink rails stood 91 points
            // above the cat's own head and 41 below its feet, on either side of
            // nothing. Padding the overflows back off is what puts the border on
            // the card and leaves the staples to be its caps.
            content
                .frame(width: layout.layerWidth)
                .frame(maxHeight: .infinity)
                .padding(.top, layout.top)
                .padding(.bottom, layout.bottom)
        } else {
            // A staple is a cap and keeps its own aspect, hanging from the edge
            // it names. The width is the card's, and the layer PNG's whole
            // authored width maps onto it — 1200 + 56 + 56 = 1312, the pixel
            // width of every layer captured so far.
            content
                .aspectRatio(contentMode: .fit)
                .frame(width: layout.layerWidth)
                .frame(maxHeight: .infinity, alignment: anchor == .top ? .top : .bottom)
        }
    }
}

struct ProfileFrameView: View {
    var frame: ProfileFrame
    /// The card's width. The only input the layout needs.
    var cardWidth: CGFloat
    /// Which pass this is: the layers behind the card, or those over it.
    ///
    /// Two views rather than one, because a `back` layer drawn in front covers
    /// the avatar it was authored to sit behind. Every layer captured so far is
    /// `front`; `back` is in the payload's vocabulary and costs one comparison
    /// to honour.
    var order: ProfileFrame.Order

    private var layers: [ProfileFrame.Layer] {
        order == .front ? frame.frontLayers : frame.backLayers
    }

    var body: some View {
        let layout = frame.layout(cardWidth: cardWidth)
        ZStack {
            ForEach(layers) { layer in
                RemoteImage(url: layer.url, side: layout.layerWidth, bucket: .artwork) {
                    Color.clear
                }
                // **A centre-anchored layer stretches over the card; the
                // others keep their aspect and hang past it.** A border runs the
                // card's whole height, so its artwork is authored uniform along
                // y and is meant to be pulled to fit — the *card's* height, not
                // the composition's, which is the correction `FrameLayerFit`
                // records. A staple is a cap and hangs from the edge it names at
                // its own aspect — the width is the card's plus both overflows,
                // and the layer PNG's whole authored width maps onto it:
                // 1200 + 56 + 56 = 1312, the pixel width of every layer captured
                // so far.
                .modifier(FrameLayerFit(anchor: layer.anchor, layout: layout))
            }
        }
        .padding(EdgeInsets(
            top: -layout.top,
            leading: -layout.leading,
            bottom: -layout.bottom,
            trailing: -layout.leading
        ))
        // The frame sits over the card's own controls and must not swallow a
        // click meant for one — the same contract `ProfileEffectView` has, and
        // for the same reason.
        .allowsHitTesting(false)
        .accessibilityHidden(frame.label == nil)
        .accessibilityLabel(Text(frame.label ?? ""))
    }
}

extension ProfileFrame {
    /// How far this frame's artwork runs past a card of `cardWidth`.
    ///
    /// The same value the surface pads by and the placement clamps against, so
    /// the two cannot disagree about where the roses are.
    func overhang(cardWidth: CGFloat) -> EdgeInsets {
        let layout = layout(cardWidth: cardWidth)
        return EdgeInsets(
            top: layout.top,
            leading: layout.leading,
            bottom: layout.bottom,
            trailing: layout.leading
        )
    }
}

extension View {
    /// Wraps this card in `frame`, and reserves the room its artwork needs.
    ///
    /// **Two halves that must agree, so they are written once.** The overlay
    /// draws past the card's edges; the padding is what makes that space part of
    /// the card's reported size, so whatever positions the card reserves it
    /// without having to know a frame is involved.
    ///
    /// Nil leaves the view untouched — no overlay, no padding, no layout change
    /// at all — which is the case for very nearly every profile.
    ///
    /// Two passes over the layers, because a `back` layer drawn in front covers
    /// the avatar it was authored to sit behind. Every layer captured so far is
    /// `front`; `back` is in the payload's vocabulary and costs one comparison.
    @ViewBuilder
    func profileFrame(_ frame: ProfileFrame?, cardWidth: CGFloat) -> some View {
        if let frame, !frame.isEmpty {
            self
                .background { ProfileFrameView(frame: frame, cardWidth: cardWidth, order: .back) }
                .overlay { ProfileFrameView(frame: frame, cardWidth: cardWidth, order: .front) }
                .padding(frame.overhang(cardWidth: cardWidth))
        } else {
            self
        }
    }

    /// Wraps a fixed-width **region** of this surface, reserving nothing.
    ///
    /// **The difference from the version above is the padding, and it is the
    /// whole difference between a card and a panel.** A card *is* the thing the
    /// artwork wraps, so whatever places it has to reserve the overhang or the
    /// roses land off screen. The full profile's identity panel is a region
    /// inside a sheet that is already centred in the window with air around it —
    /// there is nothing to reserve against, and padding here would push the
    /// content column sideways by the artwork's width the moment a frame
    /// resolved.
    ///
    /// The two passes are still two, and for the reason they always were: a
    /// `back` layer drawn in front covers the avatar it was authored to sit
    /// behind. Here that means one goes under the whole sheet and one over it.
    @ViewBuilder
    func profileFrame(
        _ frame: ProfileFrame?,
        over regionWidth: CGFloat,
        alignment: Alignment = .leading
    ) -> some View {
        if let frame, !frame.isEmpty {
            self
                .background(alignment: alignment) {
                    region(frame, regionWidth, .back)
                }
                .overlay(alignment: alignment) {
                    region(frame, regionWidth, .front)
                }
        } else {
            self
        }
    }

    /// The region the layers hang off: as wide as the panel, as tall as the
    /// surface, and drawing nothing itself.
    private func region(
        _ frame: ProfileFrame,
        _ width: CGFloat,
        _ order: ProfileFrame.Order
    ) -> some View {
        Color.clear
            .frame(width: width)
            .overlay { ProfileFrameView(frame: frame, cardWidth: width, order: order) }
            .allowsHitTesting(false)
    }
}
