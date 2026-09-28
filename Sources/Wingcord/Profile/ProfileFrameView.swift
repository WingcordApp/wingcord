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
/// Each layer then draws by its kind — Discord's rules (module `744808`) — at
/// the composition's width and its own aspect: a staple hangs past the card
/// from the edge its anchor names, a rail and a border stay inside the card's
/// height. Nothing is fitted into a box and nothing is stretched, so a layer's
/// artwork lands where it was authored however tall the card turned out to be.
///
/// **Never a glass element and never inside a `GlassEffectContainer`.** A
/// container promotes its glass above ordinary siblings and renders it itself —
/// §4 rule 4 — so a frame joined to one would draw over the card's own controls
/// instead of around them.
struct ProfileFrameView: View {
    var frame: ProfileFrame
    /// The card's width. The only input the layout needs.
    var cardWidth: CGFloat
    /// Which pass this is: the layers behind the card, or those over it.
    ///
    /// Two views rather than one, because a `back` layer drawn in front covers
    /// what it was authored to sit behind — Fantasy Galaxy's second set of
    /// clouds is one.
    var order: ProfileFrame.Order
    /// Whether a layer that lands after the card fades in.
    ///
    /// Off in the DM column, which is Discord's own split: its sidebar passes
    /// `fadeIn: false` (`r1`), while the popout fades a frame that was not
    /// already loaded when it opened (module `577390`).
    var fadesIn = true
    /// How dark the shadows its staples throw are, on a card that floats —
    /// see `FrameShadow`. Nil everywhere else, where they throw none.
    var shadowOpacity: Double?

    private var layers: [ProfileFrame.Layer] {
        order == .front ? frame.frontLayers : frame.backLayers
    }

    var body: some View {
        let layout = frame.layout(cardWidth: cardWidth)
        ZStack {
            ForEach(layers) { layer in
                FrameLayer(
                    layer: layer,
                    layout: layout,
                    cardWidth: cardWidth,
                    fadesIn: fadesIn,
                    shadowOpacity: shadowOpacity
                )
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

/// One layer, drawn by its kind inside the stack `ProfileFrameView` grew by the
/// overflows.
///
/// A branch is safe here where it usually is not: a layer's kind comes from
/// the payload and cannot change while the frame is on screen, so the arms are
/// never swapped for the same `id` and no image is ever torn down.
private struct FrameLayer: View {
    var layer: ProfileFrame.Layer
    var layout: ProfileFrameLayout
    var cardWidth: CGFloat
    var fadesIn: Bool
    var shadowOpacity: Double?

    @Environment(\.motion) private var motion

    /// How the artwork comes in when it lands after the card. See
    /// `ProfileFrameView.fadesIn`.
    private var arrival: Animation? { fadesIn ? motion.fade : nil }

    /// Discord's responsive rail stays only while the card is narrower than
    /// 300/480 of its height.
    private static let responsiveAspect: CGFloat = 300 / 480
    /// A rail's or a border's artwork is about twice as tall as it is wide —
    /// Fantasy Galaxy's and Kawaii Cat's are both 1312 × 2528 — and a decode
    /// caps the longer side, so this is what keeps the width sharp.
    private static let tallDecodeReach: CGFloat = 2

    var body: some View {
        switch layer.kind {
        case .staple:
            staple
                .frame(maxHeight: .infinity, alignment: layer.anchor == .bottom ? .bottom : .top)
                // A centre staple is unplaced in Discord's rules, which leaves
                // it at the card's top edge.
                .padding(.top, layer.anchor == .center ? layout.top : 0)
        case .rail:
            Group {
                if layer.isResponsive {
                    // The card's own height, read where it is drawn and kept
                    // nowhere: it decides only whether the rail has the room.
                    GeometryReader { proxy in
                        if cardWidth < proxy.size.height * Self.responsiveAspect { rail }
                    }
                } else {
                    rail
                }
            }
            .clipped()
            .padding(.top, layout.top)
            .padding(.bottom, layout.bottom)
        case .border:
            RemoteImage(
                url: layer.url,
                side: layout.layerWidth * Self.tallDecodeReach,
                bucket: .artwork,
                tileWidth: layout.layerWidth,
                arrival: arrival
            ) {
                Color.clear
            }
            .frame(width: layout.layerWidth)
            .clipped()
            .padding(.top, layout.top)
            .padding(.bottom, layout.bottom)
        }
    }

    /// The artwork at the composition's width and its own height — the layer
    /// PNG's whole authored width mapped onto the card plus both overflows,
    /// 1200 + 56 + 56 = 1312 on every frame captured so far. Fades in when it
    /// lands after the card, as Discord's layers do — where the surface asks.
    private func picture(side: CGFloat) -> some View {
        RemoteImage(url: layer.url, side: side, bucket: .artwork, arrival: arrival) {
            Color.clear
        }
        .aspectRatio(contentMode: .fit)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: layout.layerWidth)
    }

    /// A cap, and on a floating card the shadow it throws out from the card —
    /// up from a top staple, down from a bottom one. Discord gives a centre
    /// staple none. The branch is the surface's and the layer's, and neither
    /// changes while the frame is on screen.
    @ViewBuilder
    private var staple: some View {
        if let shadowOpacity, layer.anchor != .center {
            picture(side: layout.layerWidth)
                .shadow(
                    color: .black.opacity(shadowOpacity),
                    radius: FrameShadow.radius,
                    x: FrameShadow.offset,
                    y: layer.anchor == .bottom ? FrameShadow.offset : -FrameShadow.offset
                )
        } else {
            picture(side: layout.layerWidth)
        }
    }

    /// Inside the card's height, from the edge its anchor names; cut at the
    /// other by the clip around it.
    private var rail: some View {
        picture(side: layout.layerWidth * Self.tallDecodeReach)
            .frame(maxHeight: .infinity, alignment: railAlignment)
    }

    private var railAlignment: Alignment {
        switch layer.anchor {
        case .top: .top
        case .center: .center
        case .bottom: .bottom
        }
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
    func profileFrame(
        _ frame: ProfileFrame?,
        cardWidth: CGFloat,
        fadesIn: Bool = true,
        shadowOpacity: Double? = nil
    ) -> some View {
        if let frame, !frame.isEmpty {
            self
                .background {
                    ProfileFrameView(
                        frame: frame,
                        cardWidth: cardWidth,
                        order: .back,
                        fadesIn: fadesIn,
                        shadowOpacity: shadowOpacity
                    )
                }
                .overlay {
                    ProfileFrameView(
                        frame: frame,
                        cardWidth: cardWidth,
                        order: .front,
                        fadesIn: fadesIn,
                        shadowOpacity: shadowOpacity
                    )
                }
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

/// The shadows a framed popout casts — Discord's own (`315513.css`).
///
/// **A frame replaces the card's shadow; it does not add one.** Discord unsets
/// the popout's shadow once a frame is worn (`253781.css`) and casts a
/// card-shaped one down and to the right instead, and each staple throws its
/// own the same distance out from the card — so the artwork hanging in free
/// space casts a shadow of its own shape. Only the floating card casts them:
/// the DM column, the embed and the full profile wear the same frames with
/// none.
enum FrameShadow {
    /// How far every one of them falls: across, and down — or up, from a top
    /// staple.
    static let offset: CGFloat = 20
    /// Discord's 30-pixel blur. **Measured, not converted by rule:** SwiftUI's
    /// radius 15 and Chrome's `box-shadow` blur of 30 fall off within a
    /// hundredth of each other at every sample out to 40 points, so a radius
    /// here is half a CSS blur.
    static let radius: CGFloat = 15

    /// How dark they are, from the room the card floats in — Discord's
    /// `--custom-profile-frame-drop-shadow-opacity` (`629972.css`): 0.13 in
    /// its light theme, 0.2 in its dark one, 0.6 in Midnight. True Black is
    /// this app's Midnight; every other dark room sits on Discord's dark base,
    /// as its gradient themes do.
    static func opacity(in colors: ThemeColors) -> Double {
        if colors.appearance == .light { return 0.13 }
        return colors == .trueBlack ? 0.6 : 0.2
    }
}
