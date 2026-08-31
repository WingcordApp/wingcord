import SwiftUI

// MARK: - The eleven tiles
//
// Ten themes and the reader's own, laid out as a grid of the thing itself: each
// tile IS its theme's ramp, top-lit, with the accent as a short bar along the
// foot. Nothing here is a swatch standing in for a colour — the gradient is the
// reading surface fading up to a raised row, which is exactly the separation the
// window will have if you pick it.
//
// **The selection is a travelling ring, and the caption's weight.** Not a
// checkmark: the settings window already says elsewhere that weight is how a
// selected thing is marked and that a second mark for one state is noise. The
// ring moves between tiles with `matchedGeometryEffect` rather than fading out
// and in, which is the same treatment the channel list's pill gets and for the
// same reason — a morph beats a transition every time.

/// Layout for the theme surfaces. Design, not measurement — unlike
/// `SettingsMetrics`, none of this came off a reference window, so these are
/// tunable in a way that file's numbers deliberately are not.
nonisolated enum ThemeMetrics {
    /// The narrowest a tile may be before its accent bar and its caption stop
    /// reading as belonging to the same object.
    static let tileMinimumWidth: CGFloat = 96
    static let tileMaximumWidth: CGFloat = 148
    static let tileHeight: CGFloat = 58
    static let tileRadius: CGFloat = 11
    static let tileSpacing: CGFloat = 9
    /// The accent's mark along the foot of a tile.
    static let accentBarWidth: CGFloat = 18
    static let accentBarHeight: CGFloat = 3
    static let accentBarInset: CGFloat = 8
    /// The selection ring, drawn outside the tile so it never eats into the
    /// gradient it is marking.
    static let ringWidth: CGFloat = 2
    static let ringGap: CGFloat = 2.5
}

struct ThemeGallery: View {
    @State private var theme = ThemeStore.shared
    @Namespace private var ring

    private static let columns = [
        GridItem(
            .adaptive(minimum: ThemeMetrics.tileMinimumWidth, maximum: ThemeMetrics.tileMaximumWidth),
            spacing: ThemeMetrics.tileSpacing,
            alignment: .top
        )
    ]

    var body: some View {
        LazyVGrid(columns: Self.columns, spacing: ThemeMetrics.tileSpacing) {
            ForEach(ThemePreset.allCases) { preset in
                ThemeTile(
                    title: preset.title,
                    help: preset.summary,
                    colors: preset.colors,
                    glyph: nil,
                    isSelected: theme.choice == .preset(preset),
                    ring: ring
                ) {
                    theme.select(.preset(preset))
                }
            }
            ThemeTile(
                title: "Plumage",
                help: "Your own blend. Choosing this opens the instrument below.",
                colors: ThemeStore.colors(
                    for: .custom,
                    customSeed: theme.customSeed,
                    systemAccent: theme.customFollowsSystemAccent
                ),
                glyph: "paintbrush.pointed.fill",
                isSelected: theme.choice.isCustom,
                ring: ring
            ) {
                theme.select(.custom)
            }
        }
        .padding(SettingsMetrics.cardContentInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SettingsSurface.card)
        .clipShape(.settingsRect(SettingsMetrics.cardRadius))
    }
}

// MARK: - One tile

private struct ThemeTile: View {
    var title: String
    var help: String
    var colors: ThemeColors
    /// Drawn faintly in the corner. Only the reader's own tile has one — the ten
    /// are told apart by their colour, which is the whole point of them.
    var glyph: String?
    var isSelected: Bool
    var ring: Namespace.ID
    var select: () -> Void

    @Environment(\.motion) private var motion
    @State private var isHovered = false

    var body: some View {
        Button(action: select) {
            VStack(spacing: Spacing.tight + 1) {
                swatch
                Text(title)
                    // Weight, not colour. See the note at the top.
                    .font(isSelected
                        ? SettingsType.rowSubtitle.weight(.semibold)
                        : SettingsType.rowSubtitle)
                    .foregroundStyle(isSelected ? Ink.primary : Ink.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(motion.hover, value: isHovered)
        .animation(motion.glassMorph, value: isSelected)
        .help(help)
        .accessibilityLabel(title)
        .accessibilityHint(help)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    // No press-down scale, deliberately. Every other button in this window —
    // the navigation rows, the About page's tiles — carries its affordance in
    // the hover alone, and a tile that also dipped would be the one control here
    // that moves.

    private var swatch: some View {
        RoundedRectangle(cornerRadius: ThemeMetrics.tileRadius, style: .continuous)
            .fill(
                // **The window's own two stops, in the window's own order** —
                // the darker head at the top, the lit foot at the bottom. A tile that
                // showed the ramp instead (a card's colour fading to the ground)
                // would be a picture of a *card*, and the reader is choosing a
                // room.
                LinearGradient(
                    colors: [Color(hex: colors.canvas), Color(hex: colors.canvasLit)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(height: ThemeMetrics.tileHeight)
            .overlay(alignment: .bottomLeading) { accentBar }
            .overlay(alignment: .topTrailing) { cornerGlyph }
            .overlay {
                // A hairline at rest, because a dark tile on a dark card with no
                // edge is a region rather than an object — the same reason a
                // card on the reading surface carries one.
                RoundedRectangle(cornerRadius: ThemeMetrics.tileRadius, style: .continuous)
                    .strokeBorder(
                        Color.white.opacity(isHovered ? 0.28 : 0.10),
                        lineWidth: 1
                    )
            }
            .overlay {
                if isSelected {
                    RoundedRectangle(
                        cornerRadius: ThemeMetrics.tileRadius + ThemeMetrics.ringGap,
                        style: .continuous
                    )
                    .strokeBorder(Ink.primary, lineWidth: ThemeMetrics.ringWidth)
                    .padding(-ThemeMetrics.ringGap)
                    .matchedGeometryEffect(id: "theme.ring", in: ring)
                }
            }
    }

    /// The accent, as a short bar rather than a dot.
    ///
    /// A theme that keeps the reader's system accent has none of its own to
    /// show, and drawing the system's here would say the tile contains a colour
    /// it does not. The bar is the tile's own raised rung instead — visible, and
    /// honest about being nothing.
    private var accentBar: some View {
        Capsule()
            .fill(colors.accent.map { Color(hex: $0) } ?? Color.white.opacity(0.22))
            .frame(width: ThemeMetrics.accentBarWidth, height: ThemeMetrics.accentBarHeight)
            .padding(ThemeMetrics.accentBarInset)
    }

    @ViewBuilder
    private var cornerGlyph: some View {
        if let glyph {
            Image(systemName: glyph)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
                .padding(ThemeMetrics.accentBarInset)
        }
    }
}
