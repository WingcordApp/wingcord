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

    static func == (lhs: NowBar, rhs: NowBar) -> Bool {
        lhs.presentation == rhs.presentation
    }

    var toggleMute: () -> Void = {}
    var toggleDeafen: () -> Void = {}
    var openSettings: () -> Void = {}
    var openSelfProfile: () -> Void = {}
    var setStatus: (PresenceStatus) -> Void = { _ in }
    var setCustomStatus: (String?) -> Void = { _ in }

    @Environment(\.motion) private var motion
    @State private var isMenuOpen = false

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
        // **The tint is part of the material, not a fill behind it.** This was
        // a `RoundedRectangle().fill(selectionFill).glassEffect(...)`, which is
        // a fill *underneath* glass — the case `INVARIANTS.md` §4 rule 3
        // forbids, and the reason a glass surface stops lensing and starts
        // reading as a flat lighter panel. `.regular.tint(...)` lights the
        // material itself and keeps what is behind the window refracting
        // through it.
        .glassEffect(
            .regular.tint(Palette.selectionFill),
            in: .rect(cornerRadius: Radius.glass)
        )
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
        Button { isMenuOpen = true } label: {
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
        .accessibilityHint("Change your status")
        .popover(isPresented: $isMenuOpen, arrowEdge: .top) {
            NowBarMenu(
                presentation: presentation,
                setStatus: setStatus,
                setCustomStatus: setCustomStatus,
                openSelfProfile: openSelfProfile,
                dismiss: { isMenuOpen = false }
            )
        }
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
                        .fill(isActive ? accent.opacity(0.22) : Color.white.opacity(isHovering ? 0.16 : 0.09))
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
