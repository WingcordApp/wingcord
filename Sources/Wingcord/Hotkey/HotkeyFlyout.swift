import SwiftUI

// MARK: - The flyout
//
// A replica, measured rather than designed — see `HotkeyMetrics` for the method
// and for every number in it.
//
// Three states share one layout, and the layout does NOT move between them:
//
//   - **Idle.** The stored binding's caps, the hint, and a footer that offers
//     both ways out.
//   - **Recording.** Only the keys held right now. The hint is gone and so is
//     "or ↩" — there is nothing to accept yet.
//   - **Accepted.** The new binding, and a green wash from the top edge that
//     holds for a sixth of a second and fades over two thirds of one.
//
// The keys row and the hint row are held at FIXED heights at FIXED offsets, not
// centred in what is left. That is the reference's own choice and it is the
// right one: a hint that vanishes while the reader is watching the keys must not
// take the keys with it.

struct HotkeyFlyout: View {

    var recorder: HotkeyRecorder
    var tailEdge: VerticalEdge

    @Environment(\.motion) private var motion

    private var shape: HotkeyFlyoutShape { HotkeyFlyoutShape(tailEdge: tailEdge) }

    var body: some View {
        content
            .frame(width: HotkeyMetrics.panelWidth, height: HotkeyMetrics.panelHeight)
            // The material is the shape's, not a rectangle's — glass clipped by
            // a rounded rect draws a rounded rect, and this one has a tail.
            // The lift belongs UNDER the content and over the glass. As an
            // overlay it would sit on the key caps and the sentence too, and a
            // white film over white text is a five-percent loss of contrast on
            // every glyph in the panel.
            .background { shape.fill(HotkeySurface.lift) }
            .glassEffect(.regular, in: shape)
            .overlay { flash }
            .overlay { rim }
            .compositingGroup()
            .shadow(color: .black.opacity(0.44), radius: 7, y: 3)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Shortcut recorder")
    }

    // MARK: Content

    private var content: some View {
        VStack(spacing: 0) {
            // The body's own inset, then the two rows at their measured offsets.
            Color.clear.frame(height: HotkeyMetrics.shadowMargin + HotkeyMetrics.capsTop)
            keys
                .frame(height: HotkeyMetrics.capHeight)
            Color.clear
                .frame(height: HotkeyMetrics.hintTop - HotkeyMetrics.capsTop - HotkeyMetrics.capHeight)
            hint
                .frame(height: HotkeyMetrics.hintHeight)
            Spacer(minLength: 0)
            // The footer owns the whole band below the divider, and the divider
            // is drawn ON it rather than above it: a hairline that took its half
            // point out of the stack would push everything under it down by
            // half a point, which is exactly half a device pixel of wrong.
            footer
                .frame(height: HotkeyMetrics.footerHeight)
                .overlay(alignment: .top) {
                    HotkeySurface.divider
                        .frame(height: HotkeyMetrics.dividerHeight)
                }
            Color.clear.frame(height: HotkeyMetrics.shadowMargin)
        }
        .padding(.horizontal, HotkeyMetrics.shadowMargin)
    }

    // MARK: Keys

    /// What the caps row is showing right now.
    ///
    /// A computed property rather than state: there is exactly one source of
    /// truth — the recorder's phase — and a cached copy of it is a copy that can
    /// be stale for one frame.
    private var caps: [Hotkey.Cap] {
        switch recorder.phase {
        case .recording(let caps): caps
        case .idle, .accepted, .rejected: recorder.hotkey?.caps ?? []
        }
    }

    @ViewBuilder
    private var keys: some View {
        HStack(spacing: HotkeyMetrics.capSpacing) {
            if caps.isEmpty {
                Text("Press a shortcut")
                    .font(HotkeyMetrics.hint)
                    .foregroundStyle(Ink.tertiary)
            } else {
                ForEach(caps) { cap in
                    KeyCap(label: cap.label)
                }
            }
        }
        // The row is centred, and the whole row moves as one when a cap is added
        // or removed — which is what makes ⌃ then ⌥ then ⌘ read as a chord
        // building up rather than as three separate rows.
        .animation(motion.standard, value: caps)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(recorder.hotkey?.accessibilityDescription ?? "No shortcut set")
    }

    // MARK: Hint

    @ViewBuilder
    private var hint: some View {
        switch recorder.phase {
        case .rejected(let reason):
            Text(reason)
                .font(HotkeyMetrics.hint)
                .foregroundStyle(Palette.destructive)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        case .recording:
            // Nothing. Deliberately not a `Color.clear` of the same height —
            // the row already has one from `content`, and an empty view here is
            // what makes the transition free.
            EmptyView()
        case .idle, .accepted:
            HStack(spacing: HotkeyMetrics.hintGlyphGap) {
                // NOT the reference's "Click keys to edit further". That
                // sentence promises a per-key editor — left or right modifier,
                // physical position or key equivalent — and this recorder does
                // not have one. A settings window that offers an interaction it
                // cannot perform is worse than one that says less.
                Text("Press the keys you want to use")
                    .font(HotkeyMetrics.hint)
                    // The sentence's box centre sits above its ink centre; the
                    // glyph's does not.
                    .offset(y: HotkeyMetrics.hintTextBaselineNudge)
                Image(systemName: "info.circle")
                    .font(.system(size: HotkeyMetrics.hintGlyphSide))
                    .help(Self.keyHelp)
            }
            .foregroundStyle(Ink.tertiary)
        }
    }

    /// What the ⓘ says, and it is not decoration: a binding recorded here is
    /// stored as a key POSITION, which is the one thing about it a reader cannot
    /// see from the glyph on screen.
    private static let keyHelp = """
        Modifier keys match either side of the keyboard. \
        Character keys are recorded by physical position, so a shortcut stays \
        under the same finger when the keyboard layout changes.
        """

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 0) {
            Image(systemName: "paperplane.fill")
                .font(.system(size: 13))
                .frame(width: HotkeyMetrics.markSide, height: HotkeyMetrics.markSide)
                .foregroundStyle(Ink.primary)
            Text("Wingcord")
                .font(HotkeyMetrics.wordmark)
                .foregroundStyle(Ink.primary)
                .padding(.leading, HotkeyMetrics.markGap)
            Spacer(minLength: HotkeyMetrics.footerSpacing)
            HStack(spacing: HotkeyMetrics.footerSpacing) {
                Text("Close")
                FooterChip(label: "esc", symbol: nil)
                // Only offered once there is something to accept. The reference
                // does the same, and it is the only cue that the recorder is
                // still waiting for a key.
                if !isRecording {
                    Text("or")
                    FooterChip(label: nil, symbol: "return")
                }
            }
            .font(HotkeyMetrics.footerLabel)
            .foregroundStyle(Ink.secondary)
            .animation(motion.standard, value: isRecording)
        }
        .padding(.leading, HotkeyMetrics.footerLeading)
        .padding(.trailing, HotkeyMetrics.footerTrailing)
    }

    private var isRecording: Bool {
        if case .recording = recorder.phase { return true }
        return false
    }

    // MARK: The rim

    /// One point, drawn inside the outline, with a vertical gradient in its
    /// opacity: three times brighter along the top and bottom edges than down
    /// the sides. Stroked at twice the width and clipped, which puts the whole
    /// line inside the shape — a plain `stroke` would straddle the edge and put
    /// half of it in the shadow.
    private var rim: some View {
        shape
            .stroke(rimGradient, lineWidth: HotkeyMetrics.borderWidth * 2)
            .clipShape(shape)
            .allowsHitTesting(false)
    }

    private var rimGradient: LinearGradient {
        // Expressed as fractions of the PANEL, because that is the space the
        // overlay is laid out in, while every measurement is of the body.
        let panel = HotkeyMetrics.panelHeight
        let top = HotkeyMetrics.shadowMargin / panel
        let bottom = (panel - HotkeyMetrics.shadowMargin) / panel
        let ramp = HotkeyMetrics.cornerRadius / panel
        let side = HotkeyMetrics.borderSideOpacity
        let leading = tailEdge == .top ? HotkeyMetrics.borderTopOpacity : HotkeyMetrics.borderBottomOpacity
        let trailing = tailEdge == .top ? HotkeyMetrics.borderBottomOpacity : HotkeyMetrics.borderTopOpacity
        return LinearGradient(
            stops: [
                .init(color: .white.opacity(leading), location: 0),
                .init(color: .white.opacity(leading), location: top),
                .init(color: .white.opacity(side), location: top + ramp),
                .init(color: .white.opacity(side), location: bottom - ramp),
                .init(color: .white.opacity(trailing), location: bottom),
                .init(color: .white.opacity(trailing), location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: The flash

    /// The green wash that says a binding landed.
    ///
    /// `.plusLighter`, not a normal blend, and the reference's own pixels are
    /// what settle it: every channel of its delta is positive, which no blend
    /// toward a saturated green can produce. Additive at 7.5% reproduces all
    /// three to within one and a half parts in 255.
    private var flash: some View {
        shape
            .fill(
                LinearGradient(
                    stops: Self.flashStops,
                    startPoint: tailEdge == .top ? .top : .bottom,
                    endPoint: tailEdge == .top ? .bottom : .top
                )
            )
            .blendMode(.plusLighter)
            .opacity(recorder.isFlashing ? 1 : 0)
            // Nil on the way in: the reference's flash arrives in one frame,
            // and it was checked frame by frame rather than assumed. Only the
            // fade is animated.
            .animation(
                recorder.isFlashing ? nil : HotkeyMetrics.flashFadeCurve,
                value: recorder.isFlashing
            )
            .allowsHitTesting(false)
    }

    /// Sampled off the reference at eleven heights and normalised. Close to
    /// linear, and not quite: the top third holds its value longer than a ramp
    /// would.
    private static let flashStops: [Gradient.Stop] = [
        .init(color: flashColor(1.00), location: 0.00),
        .init(color: flashColor(0.86), location: 0.24),
        .init(color: flashColor(0.70), location: 0.42),
        .init(color: flashColor(0.41), location: 0.61),
        .init(color: flashColor(0.22), location: 0.80),
        .init(color: flashColor(0.00), location: 1.00),
    ]

    private static func flashColor(_ scale: Double) -> Color {
        Palette.affirmative.opacity(HotkeyMetrics.flashOpacity * scale)
    }
}

// MARK: - A key cap

/// One key, drawn the way the reference draws it: a fill, a half point of light
/// along the top edge, and a half point of shade under the bottom one.
private struct KeyCap: View {
    var label: String

    var body: some View {
        Text(label)
            .font(HotkeyMetrics.capLabel)
            .foregroundStyle(Ink.primary)
            .padding(.horizontal, HotkeyMetrics.capHorizontalPadding)
            .frame(minWidth: HotkeyMetrics.capMinWidth, maxHeight: .infinity)
            .frame(height: HotkeyMetrics.capHeight)
            .background {
                ZStack {
                    // The shade sits under the cap rather than around it: a
                    // symmetric shadow reads as a floating chip, and a key is
                    // pressed into a surface rather than hovering over it.
                    ZStack {
                        shape
                            .fill(HotkeySurface.capShadow)
                            .offset(y: HotkeyMetrics.capShadowOffset)
                            .blur(radius: HotkeyMetrics.capShadowBlur)
                        // **The cap's own area is punched out of its shade.**
                        // The fill is white at eleven percent, so a shadow drawn
                        // whole shows straight through it — measured, and it
                        // took the cap's contrast against the panel from ten
                        // percent down to two.
                        shape.fill(.black).blendMode(.destinationOut)
                    }
                    .compositingGroup()
                    shape.fill(HotkeySurface.cap)
                }
            }
            // `strokeBorder`, not `stroke` and a clip: the cap's shape is
            // insettable, so the line can be drawn entirely inside the edge
            // without a second render pass to cut its outer half away.
            .overlay {
                shape
                    .strokeBorder(
                        LinearGradient(
                            stops: [
                                .init(color: HotkeySurface.capHighlight, location: 0),
                                .init(color: HotkeySurface.capHighlight, location: 0.025),
                                .init(color: .clear, location: 0.06),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.6
                    )
                    .allowsHitTesting(false)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: HotkeyMetrics.capRadius, style: .continuous)
    }
}

// MARK: - A footer chip

/// The outlined key names in the footer — esc, and the return arrow.
///
/// Outlined rather than filled, which is what separates them from the caps
/// above: those are the shortcut being recorded, these are keys you may press.
private struct FooterChip: View {
    var label: String?
    var symbol: String?

    var body: some View {
        Group {
            if let symbol {
                // A glyph chip is square and the glyph is centred in it. Padding
                // would make it as wide as whatever the symbol happens to
                // measure, and `return` is half again as wide as `esc` is tall.
                Image(systemName: symbol)
                    .font(.system(size: 9))
                    .frame(width: HotkeyMetrics.chipMinWidth, height: HotkeyMetrics.chipHeight)
            } else if let label {
                Text(label.capitalized)
                    .font(HotkeyMetrics.chipLabel)
                    .padding(.horizontal, HotkeyMetrics.chipHorizontalPadding)
                    .frame(minWidth: HotkeyMetrics.chipMinWidth)
                    .frame(height: HotkeyMetrics.chipHeight)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: HotkeyMetrics.chipRadius, style: .continuous)
                .strokeBorder(HotkeySurface.chipBorder, lineWidth: HotkeyMetrics.chipBorderWidth)
        }
    }
}
