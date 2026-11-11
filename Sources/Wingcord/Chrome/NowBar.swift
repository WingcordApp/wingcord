import SwiftUI
import WingcordCore

/// The reader's own card at the foot of the sidebar: who you are, what your
/// status is, and the way into settings.
///
/// **Alex's design** (references 09 and 10 in `docs/references/2026-10-05`):
/// avatar, name, status, and one white gear. Mute and deafen live on the call
/// card above it, where the call is, and in the menu bar. With nothing else on
/// it the card is one fixed object that never changes shape.
///
/// **Floating glass over the channel list — Alex's choice (2026-10-06, and
/// again 2026-10-15).** For one build it was an opaque card below the list; he
/// asked for the glass and the float back. The redesign's pages then stopped
/// short of it, and he asked a second time: they now reach under the panel's
/// bottom inset (`SidebarPages`), and the list's bottom scroll edge stays
/// hidden (`softScrollEdgeTopOnly`) so the capsule samples the rows themselves
/// rather than an already-blurred band.
struct NowBar: View, Equatable {
    var presentation: NowBarPresentation
    /// The silhouette. Passed in rather than read from `AppSettings` here, so
    /// the settings preview can show a shape the reader has not committed to
    /// yet — and so this view still holds no reference to anything observable.
    var shape: ChromeShape = .boxy

    static func == (lhs: NowBar, rhs: NowBar) -> Bool {
        lhs.presentation == rhs.presentation && lhs.shape == rhs.shape
    }

    var openSettings: () -> Void = {}
    /// Opens the reader's own profile card, beside the identity row. See
    /// `ProfilePresenter` — the card is a window-root layer, not a
    /// presentation, because a profile frame draws outside it.
    var openProfile: () -> Void = {}
    /// Told where the identity row is, in the window root's space, so the card
    /// opens beside it — from a click here or from User › Set Status….
    var reportAnchor: (CGRect) -> Void = { _ in }

    @Environment(\.motion) private var motion
    /// Whether the pointer is on the bar, which is when the reader's own plate
    /// plays.
    @State private var isHoveringPlate = false
    /// Whether the pointer is on the name, which rolls the line to the handle.
    @State private var isHoveringIdentity = false

    private var cornerRadius: CGFloat {
        shape.cornerRadius(forHeight: Metrics.nowBarHeight)
    }

    var body: some View {
        HStack(spacing: Spacing.base) {
            identity
            Spacer(minLength: Spacing.tight)
            NowBarSettingsButton(action: openSettings)
        }
        .padding(.horizontal, Spacing.base)
        .frame(height: Metrics.nowBarHeight)
        // **`.regular`, untinted** (Alex, 2026-10-15). Once rows really passed
        // under it, `.clear` let a conversation's name read straight through
        // the reader's own — the frosted variant keeps the rows moving behind
        // the bar without letting their words collide with it. Untinted, as
        // before: a tint is a flat value added to every pixel of the surface
        // (measured: it doubled the veil a reference client carries).
        .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        // **The plate goes over the material, never behind it.** Clipped to
        // the bar's shape and held under full strength, so what is behind the
        // window still refracts through and the name and the gear stay
        // legible.
        .overlay {
            if let url = presentation.nameplateURL {
                NowBarPlate(
                    still: url,
                    animated: presentation.nameplateAnimatedURL,
                    palette: presentation.nameplatePalette,
                    // **Under the pointer, like every other plate in the app.**
                    // This one is on screen for the whole session, so a loop
                    // that always ran would be a display-link subscriber and
                    // twelve megabytes of decoded film for as long as the app
                    // is open — paid by every reader who owns a plate, whether
                    // or not anybody ever looks at it.
                    isAnimating: isHoveringPlate
                )
                .clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
                .allowsHitTesting(false)
            }
        }
        .onHover { hovering in
            guard isHoveringPlate != hovering else { return }
            isHoveringPlate = hovering
        }
        .specularEdge(in: .rect(cornerRadius: cornerRadius))
        .animation(motion.glassMorph, value: shape)
        // A plate arriving, changing or being switched off in Settings changes
        // the ramp over the material; a cut between two saturated hues on the one
        // surface that is always on screen reads as a glitch.
        .animation(motion.standard, value: presentation.nameplatePalette)
        .padding(.horizontal, Spacing.base)
        .padding(.bottom, Spacing.base)
    }

    /// The identity row, and the panel it opens.
    private var identity: some View {
        Button(action: openProfile) {
            HStack(spacing: Spacing.base) {
                AvatarView(
                    url: presentation.avatarURL,
                    monogram: presentation.monogram,
                    side: Metrics.avatarRow
                )
                .overlay(alignment: .bottomTrailing) {
                    PresenceDot(status: presentation.status, side: 10)
                        .offset(x: 1, y: 1)
                }

                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: Spacing.tight) {
                        // The reader's own style: there to see, and moving
                        // under the pointer — Discord's account panel
                        // (`hovered ? ANIMATED : STATIC`).
                        StyledDisplayName(
                            text: presentation.displayName,
                            style: presentation.nameStyle,
                            textStyle: .body,
                            weight: .semibold,
                            animates: isHoveringIdentity
                        )
                        .lineLimit(1)
                        if let tag = presentation.tag {
                            SidebarTagChip(text: tag, badgeURL: presentation.tagBadgeURL)
                        }
                    }
                    subtitle
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            guard isHoveringIdentity != hovering else { return }
            isHoveringIdentity = hovering
        }
        .accessibilityLabel(Text(presentation.displayName))
        .accessibilityValue(Text(
            presentation.activityLine.map { "\(presentation.status.label), \($0.spokenText)" }
                ?? presentation.status.label
        ))
        // **The card is raised through the store, not presented here.** It was a
        // `.popover` for one build and that was the bug: a popover is an
        // `NSWindow` and cannot draw past its own frame, so a profile FRAME —
        // the decoration that hangs over the top of a card — was clipped to
        // nothing. `INVARIANTS.md` §2. `ProfilePresenter` draws it at the window
        // root, where every other profile card in the app already is.
        .reportsPresentationAnchor(reportAnchor)
    }

    /// The second line, and the handle it rolls to under the pointer — Discord's
    /// account panel, where the line rolls up to show the username.
    ///
    /// **Both leave upward and come back downward**, so the roll reads as one
    /// strip passing behind a slot rather than two labels cross-fading. Under
    /// Reduce Motion it is the fade alone.
    private var subtitle: some View {
        ZStack(alignment: .leading) {
            if isHoveringIdentity {
                Text(presentation.handle)
                    .font(Typeface.rowSubtitle)
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(1)
                    .transition(roll(from: .bottom))
            } else {
                HStack(spacing: 3) {
                    // Muted or deafened, said where the reader looks for their
                    // own state now that the switches are on the call card.
                    if let mark = voiceMark {
                        Image(symbol: mark)
                            .font(Typeface.rowSubtitle)
                            .foregroundStyle(Palette.destructive)
                        Text(verbatim: "·")
                            .font(Typeface.rowSubtitle)
                            .foregroundStyle(Ink.tertiary)
                    }
                    if let line = presentation.activityLine {
                        ActivityLineView(line: line, ink: Ink.secondary, playsEmoji: isHoveringIdentity)
                    } else {
                        Text(presentation.status.label)
                            .font(Typeface.rowSubtitle)
                            .foregroundStyle(presentation.status.tint)
                            .lineLimit(1)
                    }
                }
                .transition(roll(from: .top))
            }
        }
        .clipped()
        .animation(motion.hover, value: isHoveringIdentity)
    }

    private var voiceMark: String? {
        if presentation.isDeafened { return "headphones.slash" }
        if presentation.isMuted { return "mic.slash.fill" }
        return nil
    }

    private func roll(from edge: Edge) -> AnyTransition {
        motion.reduceMotion ? .opacity : .move(edge: edge).combined(with: .opacity)
    }
}

/// The white gear: the now bar's one control.
private struct NowBarSettingsButton: View {
    var action: () -> Void

    @Environment(\.motion) private var motion
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(symbol: "gearshape.fill")
                .font(.system(.title3, weight: .medium))
                .foregroundStyle(InkColor.primary)
                .frame(width: Metrics.control, height: Metrics.control)
                .background {
                    Circle().fill(isHovering ? Palette.hoverFill : .clear)
                }
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.hover, value: isHovering)
        .help("User Settings")
        .accessibilityLabel(Text("User Settings"))
    }
}

/// The presence dot beside an avatar.
///
/// A ring in the window's own background colour separates it from whatever it
/// overlaps — a material there would read as a blur smudge over artwork.
struct PresenceDot: View {
    var status: PresenceStatus
    var side: CGFloat
    /// The device an online mark is drawn as: a phone or a headset where the
    /// person is on one and nowhere else. Nothing but online reads it.
    var client: PresenceClient = .desktop
    /// The opaque disc behind the dot, which separates it from whatever it
    /// overlaps.
    ///
    /// **Off on a profile, where the separation is a hole rather than a disc.**
    /// A plate is a flat circle of the window's background colour painted over
    /// the artwork; against a profile banner that reads as a black blot stuck to
    /// the avatar. There the gap is cut out of the avatar instead, so what shows
    /// through it is the card's own ground.
    var hasPlate: Bool = true

    /// The phone or the headset, for somebody online on one.
    private var deviceMark: PresenceClient? {
        status == .online && client != .desktop ? client : nil
    }

    var body: some View {
        if let deviceMark {
            device(deviceMark)
        } else {
            dot
        }
    }

    /// Discord's own two masks, at the size its avatar gives them: the phone
    /// half again as tall as the dot, the headset half again as wide.
    private func device(_ client: PresenceClient) -> some View {
        let size = PresenceMarkArt.size(for: client, side: side)
        let gap = hasPlate ? side * 0.16 : 0
        return Canvas { context, canvas in
            let box = CGRect(origin: .zero, size: canvas).insetBy(dx: gap, dy: gap)
            if hasPlate {
                context.fill(
                    Path(PresenceMarkArt.silhouette(for: client, in: box, gap: gap)),
                    with: .color(Color(nsColor: .windowBackgroundColor))
                )
            }
            if let mark = PresenceMarkArt.path(for: client, in: box) {
                context.fill(Path(mark), with: .color(status.tint), style: FillStyle(eoFill: true))
            }
        }
        .frame(width: size.width + gap * 2, height: size.height + gap * 2)
        .accessibilityHidden(true)
    }

    private var dot: some View {
        Group {
            switch status {
            case .idle:
                // A crescent, not a filled dot: idle and online differ by hue
                // alone otherwise, and hue is the first thing a colour-blind
                // reader loses.
                Circle()
                    .fill(status.tint)
                    .overlay(alignment: .topLeading) {
                        Circle()
                            .fill(Color(nsColor: .windowBackgroundColor))
                            .frame(width: side * 0.62, height: side * 0.62)
                            .offset(x: -side * 0.1, y: -side * 0.1)
                    }
            case .doNotDisturb:
                Circle()
                    .fill(status.tint)
                    .overlay {
                        Capsule()
                            .fill(Color(nsColor: .windowBackgroundColor))
                            .frame(width: side * 0.56, height: side * 0.20)
                    }
            case .offline, .invisible:
                Circle()
                    .strokeBorder(status.tint, lineWidth: side * 0.28)
            case .online:
                Circle().fill(status.tint)
            case .unknown:
                // Discord's UNKNOWN — an app that never connects — has no
                // status to draw, and no plate under the nothing.
                EmptyView()
            }
        }
        .frame(width: side, height: side)
        .padding(hasPlate ? side * 0.16 : 0)
        .background {
            if hasPlate, status != .unknown {
                Circle().fill(Color(nsColor: .windowBackgroundColor))
            }
        }
        .accessibilityHidden(true)
    }
}


/// The reader's own nameplate, over their name in the now bar: a ramp of its
/// palette with the artwork hung off the trailing end.
///
/// **The ramp is where the colour lives now.** It used to be a flat tint in the
/// bar's own glass, on the argument that a plate colours the whole surface
/// rather than a patch of it; measured against a reference client, the
/// strength was wrong and the argument was not. A ramp keeps both halves: it
/// closes the gap the strip's transparent leading two thirds leave, and it is
/// almost nothing under the name, which is where a flat tint did its damage.
///
/// **It sits over the material rather than behind it**: a fill behind glass
/// is what would take the lensing away.
private struct NowBarPlate: View {
    var still: URL
    var animated: URL?
    var palette: NameplatePalette
    var isAnimating: Bool

    /// How strongly the plate reads: high enough to be the reader's own
    /// artwork, low enough that the glass underneath still shows what is
    /// behind the window.
    private static let strength: Double = 0.55

    /// The ramp's two ends, before `strength` is applied.
    ///
    /// **Measured off a client that gets this right**, not picked: over a ground
    /// of (35,34,34) its bar reads (67,61,71) at the leading edge and (85,68,101)
    /// at the trailing, which backs out to roughly a tenth of the palette under
    /// the name and four tenths under the artwork. At `strength` that is 5.5%
    /// and 22% — against the 42% flat wash this replaces.
    private static let rampLeading: Double = 0.1
    private static let rampTrailing: Double = 0.4

    /// How wide the strip comes out once it is fitted to the bar's height. See
    /// `SidebarNameplate.artWidth` for why the box is reserved rather than
    /// taken from the picture.
    ///
    /// **245 points, against a bar of 164 to 284** as the reader drags the
    /// column — so which end overflows depends on how wide they have made it,
    /// and both cases have to be right. Narrow, the strip is wider than the bar
    /// and the clip takes its leading, transparent end; wide, the strip hangs
    /// off the trailing edge and leaves bare bar beside it, which the ramp
    /// covers.
    /// `NowBarPlateTests` pins the crossover.
    private static var artWidth: CGFloat {
        (Metrics.nowBarHeight * Nameplate.artworkAspect).rounded()
    }

    var body: some View {
        // **`Color.clear` is the box, and that is load-bearing.** The strip is
        // wider than the bar, so anything that sizes itself from the artwork
        // reports *more* than it was proposed — and the caller's `clipShape`
        // then rounds that oversized rect instead of the capsule, which spills
        // the plate out of both ends. A colour takes exactly the proposal and
        // can never report more; the overlay overflows it and the clip is the
        // bar's own shape. The wash that used to hold this box open did the job
        // by accident.
        Color.clear
            // Under the artwork, so a strip whose own alpha ramps in over its
            // trailing third lands on a plate that is already going the same
            // way. Nothing at all for a palette of `.none`: a nameplate that
            // asked for no colour must not be given one.
            .overlay { ramp }
            .overlay(alignment: .trailing) {
                // Fitted to the bar's HEIGHT and hung off its trailing edge,
                // which is the measured rule — see
                // `MemberRowGeometry.nameplateArtRect`. Aspect-*fill* lands on
                // the width for a wide plate and stretches it vertically.
                NameplateArtwork(
                    still: still,
                    animated: animated,
                    width: Self.artWidth,
                    isAnimating: isAnimating
                )
                .frame(width: Self.artWidth, height: Metrics.nowBarHeight)
            }
            .opacity(Self.strength)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var ramp: some View {
        if let value = palette.colorValue {
            let colour = Color(hex: value)
            LinearGradient(
                stops: [
                    .init(color: colour.opacity(Self.rampLeading), location: 0),
                    .init(color: colour.opacity(Self.rampTrailing), location: 1),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }
}
