import SwiftUI
import WingcordCore

/// The floating identity capsule at the foot of the sidebar: who you are, what
/// your status is, and the three controls that belong to *you* rather than to
/// the conversation.
///
/// It floats over the channel list rather than sitting under it. Attached with
/// `.safeAreaBar` — not `.safeAreaInset` — so the list both reserves its height
/// **and** registers it as a bar, which is what the scroll-edge effect keys off:
/// channels passing beneath it blur into it instead of sliding under it sharp.
///
/// **The three controls are regions inside the bar's material, not glass bodies
/// on top of it.** Stacking `.glassEffect` on a control inside a glass capsule
/// is glass on glass — the inner one has the outer one's blurred output to
/// sample rather than the content behind the window, so it renders as a flat
/// lighter disc and the whole bar loses its depth. A tinted region inherits the
/// capsule's material and reads as part of it.
struct NowBar: View, Equatable {
    var presentation: NowBarPresentation
    /// The silhouette. Passed in rather than read from `AppSettings` here, so
    /// the settings preview can show a shape the reader has not committed to
    /// yet — and so this view still holds no reference to anything observable.
    var shape: ChromeShape = .boxy

    static func == (lhs: NowBar, rhs: NowBar) -> Bool {
        lhs.presentation == rhs.presentation && lhs.shape == rhs.shape
    }

    var toggleMute: () -> Void = {}
    var toggleDeafen: () -> Void = {}
    var openSettings: () -> Void = {}
    /// Opens the reader's own profile card, beside the capsule that asked for
    /// it. See `ProfilePresenter` — the card is a window-root layer, not a
    /// presentation, because a profile frame draws outside it.
    var openProfile: (CGRect) -> Void = { _ in }

    @Environment(\.motion) private var motion
    /// The identity capsule's own frame, in the window root's space, so the
    /// card opens beside it rather than at the window's corner.
    @State private var anchor: CGRect = .zero
    /// Whether the pointer is on the bar, which is when the reader's own plate
    /// plays.
    @State private var isHoveringPlate = false

    private var cornerRadius: CGFloat {
        shape.cornerRadius(forHeight: Metrics.nowBarHeight)
    }

    /// What lights the bar's material.
    ///
    /// **Neutral, and the same whoever the reader is.** This carried the
    /// nameplate's own hue at 0.42 for a while, on the argument that a plate
    /// colours the whole capsule rather than a patch of it. Measured against a
    /// client that gets this right, that argument is sound and the number was
    /// not: over a themed sidebar of (66,38,32) the bar came out (117,74,130) —
    /// the blue channel four times its ground — where the reference lifts
    /// (35,34,34) to (67,61,71), a veil that is very nearly neutral with about
    /// six units of hue in it. A capsule that is the one saturated object in the
    /// window stops reading as glass and starts reading as a painted plate,
    /// which is what it looked like.
    ///
    /// So the hue moved to where the reference keeps it — a ramp inside
    /// `NowBarPlate`, weakest under the name and strongest under the artwork.
    ///
    /// **And there is no neutral lift left either, which is the second half of
    /// the same measurement.** White at 0.15 went in on the argument that the
    /// selected channel's fill is the same value three rows up the same column.
    /// It is, and it was still too much: measured on the running window, this
    /// bar lifted a ground of `30,31,34` to `99,95,108` — plus 68 — against the
    /// reference's plus 30 on a ground of its own. `.clear` on its own accounts
    /// for about 34 of that, so the tint was the whole of the difference and
    /// removing it lands within a few units of the client this was measured
    /// against.
    ///
    /// The bar is still an object without it: the specular edge draws its
    /// silhouette, the three controls carry their own fills, and a reader who
    /// wears a plate has the ramp. What it no longer has is a flat veil
    /// standing between the channel list and the material that is supposed to
    /// be refracting it — which is what "it is not liquid glassing" meant.

    var body: some View {
        // **The call is not drawn here any more.** It used to be a line above
        // the identity row, which meant the bar changed height whenever
        // somebody joined a channel and the whole channel list re-laid out under
        // it. The call is its own floating panel — `VoiceHUD` — stacked above
        // this one, so the identity capsule is one fixed object again.
        HStack(spacing: Spacing.base) {
            identity
            Spacer(minLength: Spacing.tight)
            controls
        }
        .padding(.horizontal, Spacing.base)
        .frame(height: Metrics.nowBarHeight)
        // One capsule for the whole bar. The controls above are regions inside
        // it, never bodies on top of it.
        //
        // **`.clear`, not `.regular`.** This bar floats over the sidebar
        // column, and that column is the one surface in the window that is
        // *nothing* — behind-window vibrancy, so what passes under the capsule
        // is the reader's own desktop plus the channel list. §4's split sends
        // clear glass wherever there is media or a lit ground behind the
        // surface, and frosting a wallpaper into grey is exactly the loss the
        // material exists to avoid. `.regular` here is what made the bar read
        // as a plate rather than as glass.
        //
        // **And untinted.** A tint lights the material rather than sitting
        // behind it, so it is not §4 rule 3 — but it is still a flat value
        // added to every pixel of the surface, and at 0.15 it was more than
        // twice the veil the reference client carries. See the note on this
        // type: the measurement is `30,31,34` to `99,95,108` with it, against
        // plus 30 without.
        .glassEffect(.clear, in: .rect(cornerRadius: cornerRadius))
        // **The plate goes OVER the material, never behind it.** A fill behind
        // glass is §4 rule 3 and is exactly what stops a surface lensing; the
        // artwork belongs on top, the way a nameplate sits over a roster row's
        // own material. Clipped to the bar's shape and held well under full
        // strength, so what is behind the window still refracts through.
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
        // the ramp over the material; a cut between two saturated hues on the
        // one surface that is always on screen reads as a glitch.
        .animation(motion.standard, value: presentation.nameplatePalette)
        .padding(.horizontal, Spacing.base)
        .padding(.bottom, Spacing.base)
    }

    /// The identity row, and the panel it opens.
    ///
    /// **One popover on one view**, which is what makes a presentation modifier
    /// legitimate here: the rule it would otherwise break — never a `.popover`
    /// on a row — exists because a popover written into a list row is evaluated
    /// by every row on every pass. There is exactly one now bar.
    private var identity: some View {
        Button { openProfile(anchor) } label: {
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
                    Text(presentation.displayName)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(Ink.primary)
                        .lineLimit(1)
                    Text(presentation.customStatus ?? presentation.status.label)
                        .font(Typeface.rowSubtitle)
                        .foregroundStyle(
                            presentation.customStatus == nil
                                ? AnyShapeStyle(presentation.status.tint)
                                : AnyShapeStyle(Ink.secondary)
                        )
                        .lineLimit(1)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(presentation.displayName))
        .accessibilityValue(Text(presentation.status.label))
        .accessibilityHint("Open your profile")
        // **The card is raised through the store, not presented here.** It was a
        // `.popover` for one build and that was the bug: a popover is an
        // `NSWindow` and cannot draw past its own frame, so a profile FRAME —
        // the decoration that hangs over the top of a card — was clipped to
        // nothing. `INVARIANTS.md` §2. `ProfilePresenter` draws it at the window
        // root, where every other profile card in the app already is.
        .reportsPresentationAnchor { anchor = $0 }
    }

    private var controls: some View {
        HStack(spacing: Spacing.tight) {
            NowBarControl(
                systemImage: presentation.isMuted ? "mic.slash.fill" : "mic.fill",
                isActive: presentation.isMuted,
                accent: Palette.destructive,
                label: presentation.isMuted ? "Unmute" : "Mute",
                action: toggleMute
            )
            NowBarControl(
                systemImage: presentation.isDeafened ? "headphones.slash" : "headphones",
                isActive: presentation.isDeafened,
                accent: Palette.destructive,
                label: presentation.isDeafened ? "Undeafen" : "Deafen",
                action: toggleDeafen
            )
            NowBarControl(
                systemImage: "gearshape.fill",
                isActive: false,
                accent: Palette.accent,
                label: "Settings",
                action: openSettings
            )
        }
    }
}

/// One control inside the now bar.
///
/// A region in the parent's material: a fill and a glyph, with no material of
/// its own. The hover and active states are changes to that fill, which is the
/// only way to light a control inside glass without stacking a second body on
/// top of the first.
private struct NowBarControl: View {
    var systemImage: String
    var isActive: Bool
    var accent: Color
    var label: String
    var action: () -> Void

    @Environment(\.motion) private var motion
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(.footnote, weight: .medium))
                .foregroundStyle(isActive ? AnyShapeStyle(accent) : AnyShapeStyle(Ink.primary))
                .frame(width: Metrics.compactControl, height: Metrics.compactControl)
                .background {
                    Circle()
                        .fill(isActive ? accent.opacity(0.22) : isHovering ? nowBarControlHovered : Palette.edge)
                }
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.hover, value: isHovering)
        .animation(motion.standard, value: isActive)
        .help(label)
        .accessibilityLabel(Text(label))
    }
}

/// The presence dot beside an avatar.
///
/// A ring in the window's own background colour separates it from whatever it
/// overlaps — a material there would read as a blur smudge over artwork.
struct PresenceDot: View {
    var status: PresenceStatus
    var side: CGFloat
    var isOnMobile: Bool = false
    /// The opaque disc behind the dot, which separates it from whatever it
    /// overlaps.
    ///
    /// **Off on a profile, where the separation is a hole rather than a disc.**
    /// A plate is a flat circle of the window's background colour painted over
    /// the artwork; against a profile banner that reads as a black blot stuck to
    /// the avatar. There the gap is cut out of the avatar instead, so what shows
    /// through it is the card's own ground.
    var hasPlate: Bool = true

    var body: some View {
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
            }
        }
        .frame(width: side, height: side)
        .padding(hasPlate ? side * 0.16 : 0)
        .background {
            if hasPlate {
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
/// capsule's own material, on the argument that a plate colours the whole
/// surface rather than a patch of it — see `NowBar.lift` for the measurement
/// that overturned the strength, not the argument. A ramp keeps both halves: it
/// closes the gap the strip's transparent leading two thirds leave, and it is
/// almost nothing under the name, which is where a flat tint did its damage.
///
/// **It sits over the material rather than behind it**: a fill behind glass is
/// §4 rule 3, and it is what would take the lensing away.
private struct NowBarPlate: View {
    var still: URL
    var animated: URL?
    var palette: NameplatePalette
    var isAnimating: Bool

    /// How strongly the plate reads. High enough to be the reader's own
    /// artwork, low enough that the glass underneath still shows what is behind
    /// the window — which is the whole reason the bar is glass.
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
    /// off the trailing edge and leaves bare bar beside it, which is the half
    /// of the plate the tinted material is now covering.
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

/// A now-bar control under the pointer: light on a dark room's glass, shade on a
/// light one's.
private let nowBarControlHovered = Color.relative(dark: 0.16, light: 0.14)
