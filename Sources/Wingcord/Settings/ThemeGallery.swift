import SwiftUI
import WingcordCore

// MARK: - The tiles
//
// Two galleries, one vocabulary. The house gallery is ten themes and the
// reader's own, each tile IS the room its theme makes — the page, the frame
// down its leading edge, the light in its corner — with the accent as a short
// bar where the send arrow is. The Discord gallery is Discord's themes, each
// tile its gradient at Discord's own angle, the way Discord's picker shows it.
//
// **The selection is a travelling ring, and the caption's weight.** Not a
// checkmark: the settings window already says elsewhere that weight is how a
// selected thing is marked and that a second mark for one state is noise. The
// ring moves between tiles with `matchedGeometryEffect` rather than fading out
// and in, which is the same treatment the channel list's pill gets and for the
// same reason — a morph beats a transition every time. **One ring across both
// galleries**: they are one choice, so the ring travels from a house tile to a
// Discord one rather than vanishing from one grid and appearing in the other.

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
    /// How much of a house tile's width is the sidebar: about what the column
    /// is of a window, so the tile is the room at a glance.
    static let frameShare: CGFloat = 0.26
    /// The edge between a swatch and the card it sits on — so it follows the
    /// window's room rather than the tile's.
    static let hairline = Color.relative(dark: 0.10, light: 0.12)
    static let hairlineHovered = Color.relative(dark: 0.28, light: 0.30)
}

struct ThemeGallery: View {
    /// Shared with `DiscordThemeGallery`. See the note at the top.
    var ring: Namespace.ID

    @State private var theme = ThemeStore.shared

    var body: some View {
        // Read once here, so each tile is handed a value rather than each
        // registering its own dependency on it.
        let vividness = theme.vividness
        ThemeGrid {
            ThemeTile(
                title: "Sync with computer",
                help: nil,
                isSelected: theme.choice == .system,
                ring: ring
            ) {
                theme.select(.system)
            } swatch: {
                SystemSwatch()
            }
            ForEach(ThemePreset.allCases) { preset in
                ThemeTile(
                    title: preset.title,
                    help: preset.summary,
                    isSelected: theme.choice == .preset(preset),
                    ring: ring
                ) {
                    theme.select(.preset(preset))
                } swatch: {
                    RoomSwatch(
                        ground: preset.ground(vividness: vividness),
                        accent: preset.colors(vividness: vividness).accent
                    )
                }
            }
            PlumageTile(ring: ring)
        }
    }
}

/// Both rooms "Sync with computer" can be, split down the middle — the light
/// one leading, as the system's own Auto appearance draws its tile.
private struct SystemSwatch: View {
    var body: some View {
        let light = ThemePreset.following(systemIsDark: false)
        let dark = ThemePreset.following(systemIsDark: true)
        RoomSwatch(ground: light.ground(vividness: 0), accent: light.colors(vividness: 0).accent)
            .overlay {
                RoomSwatch(ground: dark.ground(vividness: 0), accent: dark.colors(vividness: 0).accent)
                    .mask {
                        HStack(spacing: 0) {
                            Color.clear
                            Color.black
                        }
                    }
            }
    }
}

/// The reader's own blend, in its own view.
///
/// **So a Plumage drag redraws one tile, not eleven.** The blend changes on
/// every event of a drag; read in the gallery's body, that dependency would
/// re-derive every preset's room per event to redraw the one tile that moved.
private struct PlumageTile: View {
    var ring: Namespace.ID

    @State private var theme = ThemeStore.shared

    var body: some View {
        // **"Custom", Discord's own word for a theme somebody makes**, so the
        // tile says what choosing it does; Plumage is the instrument it opens
        // below (Alex, 2026-10-07).
        ThemeTile(
            title: "Custom",
            help: "Your own blend. Choosing this opens Plumage below.",
            isSelected: theme.choice.isCustom,
            ring: ring
        ) {
            theme.select(.custom)
        } swatch: {
            RoomSwatch(
                ground: ThemeStore.ground(
                    for: .custom,
                    customSeed: theme.customSeed,
                    vividness: theme.vividness
                ),
                accent: ThemeStore.colors(
                    for: .custom,
                    customSeed: theme.customSeed,
                    systemAccent: theme.customFollowsSystemAccent,
                    vividness: theme.vividness
                ).accent,
                glyph: "paintbrush.pointed.fill"
            )
        }
    }
}

struct DiscordThemeGallery: View {
    /// Shared with `ThemeGallery`. See the note at the top.
    var ring: Namespace.ID

    @State private var theme = ThemeStore.shared

    var body: some View {
        ThemeGrid {
            ForEach(DiscordTheme.allCases) { discord in
                ThemeTile(
                    title: discord.title,
                    help: nil,
                    isSelected: theme.choice == .discord(discord),
                    ring: ring
                ) {
                    theme.select(.discord(discord))
                } swatch: {
                    DiscordSwatch(theme: discord)
                }
            }
        }
    }
}

/// The card both galleries sit in.
private struct ThemeGrid<Content: View>: View {
    @ViewBuilder var content: Content

    private static var columns: [GridItem] {
        [
            GridItem(
                .adaptive(minimum: ThemeMetrics.tileMinimumWidth, maximum: ThemeMetrics.tileMaximumWidth),
                spacing: ThemeMetrics.tileSpacing,
                alignment: .top
            )
        ]
    }

    var body: some View {
        LazyVGrid(columns: Self.columns, spacing: ThemeMetrics.tileSpacing) {
            content
        }
        .padding(SettingsMetrics.cardContentInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SettingsSurface.card)
        .clipShape(.settingsRect(SettingsMetrics.cardRadius))
    }
}

// MARK: - One tile

private struct ThemeTile<Swatch: View>: View {
    var title: String
    /// The tooltip and the VoiceOver hint. Nil where there is nothing to say
    /// beyond the name — Discord's themes carry no descriptions of their own,
    /// and inventing them would put words in Discord's mouth.
    var help: String?
    var isSelected: Bool
    var ring: Namespace.ID
    var select: () -> Void
    @ViewBuilder var swatch: Swatch

    @Environment(\.motion) private var motion
    @State private var isHovered = false

    var body: some View {
        Button(action: select) {
            VStack(spacing: Spacing.tight + 1) {
                framedSwatch
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
        .help(help ?? "")
        .accessibilityLabel(title)
        .accessibilityHint(help ?? "")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    // No press-down scale, deliberately. Every other button in this window —
    // the navigation rows, the About page's tiles — carries its affordance in
    // the hover alone, and a tile that also dipped would be the one control here
    // that moves.

    private var framedSwatch: some View {
        swatch
            .frame(height: ThemeMetrics.tileHeight)
            .clipShape(.rect(cornerRadius: ThemeMetrics.tileRadius, style: .continuous))
            .overlay {
                // A hairline at rest, because a dark tile on a dark card with no
                // edge is a region rather than an object — the same reason a
                // card on the reading surface carries one.
                RoundedRectangle(cornerRadius: ThemeMetrics.tileRadius, style: .continuous)
                    .strokeBorder(
                        isHovered ? ThemeMetrics.hairlineHovered : ThemeMetrics.hairline,
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
}

// MARK: - The two kinds of swatch

/// A house theme, drawn as **the room it makes**: the page's field at the
/// window's own angle, the frame down the leading edge where the sidebar is, and
/// the light in the bottom-trailing corner. A tile that showed the ramp instead
/// (a card's colour fading to the ground) would be a picture of a *card*, and
/// the reader is choosing a room.
///
/// A `Canvas` for the same reason as `DiscordSwatch`: the angle is laid out
/// against the tile's real size.
private struct RoomSwatch: View {
    var ground: ThemeGround
    var accent: UInt32?
    /// Drawn faintly in the corner. Only the reader's own tile has one — the ten
    /// are told apart by their colour, which is the whole point of them.
    var glyph: String?

    var body: some View {
        Canvas { context, size in
            let box = CGRect(origin: .zero, size: size)
            // One line for both columns, exactly as the window has it.
            let (start, end) = GradientAxis.endpoints(angle: ground.angle, in: box)
            context.fill(Path(box), with: .linearGradient(ground.page, startPoint: start, endPoint: end))
            if ground.paintsFrame {
                let frame = CGRect(x: 0, y: 0, width: size.width * ThemeMetrics.frameShare, height: size.height)
                context.fill(Path(frame), with: .linearGradient(ground.frame, startPoint: start, endPoint: end))
            }
            if let glow = ground.glow {
                context.fill(Path(box), with: .radialGradient(
                    glow,
                    center: CGPoint(x: size.width, y: size.height),
                    startRadius: 0,
                    endRadius: ThemeGround.glowReach * hypot(size.width, size.height)
                ))
            }
        }
        .overlay(alignment: .bottomTrailing) { accentBar }
        .overlay(alignment: .topTrailing) { cornerGlyph }
    }

    /// The accent, as a short bar rather than a dot — in the bottom-trailing
    /// corner, which is where the window spends it: the send arrow.
    ///
    /// A theme that keeps the reader's system accent has none of its own to
    /// show, and drawing the system's here would say the tile contains a colour
    /// it does not. The bar is the tile's own raised rung instead — visible, and
    /// honest about being nothing.
    private var accentBar: some View {
        Capsule()
            // Against the swatch, not the window: a light room's tile sits in a
            // dark settings window as often as the other way round.
            .fill(accent.map { Color(hex: $0) }
                ?? (ground.appearance == .light ? Color.black : Color.white).opacity(0.22))
            .frame(width: ThemeMetrics.accentBarWidth, height: ThemeMetrics.accentBarHeight)
            .padding(ThemeMetrics.accentBarInset)
    }

    @ViewBuilder
    private var cornerGlyph: some View {
        if let glyph {
            Image(symbol: glyph)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle((ground.appearance == .light ? Color.black : Color.white).opacity(0.55))
                .padding(ThemeMetrics.accentBarInset)
        }
    }
}

/// One of Discord's themes: its gradient **bare and at its own angle**, which is
/// how Discord's picker shows it and what makes each one recognisable.
///
/// Not the window's veiled ground, deliberately. Under the reading surface's
/// 80 % the fourteen are fourteen near-blacks, and the difference between
/// Sunset and Mars is the whole reason to be choosing between them.
///
/// **No accent bar.** All fourteen keep the reader's system accent, so the bar
/// would be the same mark on every tile and say nothing about any of them.
///
/// A `Canvas` because the angle is laid out the way CSS lays it out, against
/// the tile's real size — see `GradientAxis` — and a canvas is handed that size
/// without a geometry reader or a state write.
private struct DiscordSwatch: View {
    var theme: DiscordTheme

    var body: some View {
        Canvas { context, size in
            let box = CGRect(origin: .zero, size: size)
            let (start, end) = GradientAxis.endpoints(angle: theme.angle, in: box)
            context.fill(
                Path(box),
                with: .linearGradient(theme.gradient, startPoint: start, endPoint: end)
            )
        }
    }
}

// MARK: - Saved themes

/// Themes kept from conversations — Discord's theme card's Save — and the
/// account's own, as Discord's Appearance panel lists them
/// (`GET /users/@me/custom-themes`, asked as the gallery appears, as Discord
/// asks when its panel opens). Choosing one makes it the reader's theme.
struct SavedThemeGallery: View {
    /// Shared with the other galleries: the choice is one choice.
    var ring: Namespace.ID

    @Environment(AppModel.self) private var model
    @State private var theme = ThemeStore.shared
    @State private var shareRequest: ThemeShareRequest?

    var body: some View {
        Group {
            if theme.savedThemes.isEmpty && accountOnly.isEmpty {
                SettingsCard {
                    SettingsValueRow(
                        title: "None yet",
                        value: "—",
                        help: "Save a theme someone shares in a chat and it lands here."
                    )
                }
            } else {
                ThemeGrid {
                    ForEach(theme.savedThemes) { saved in
                        tile(saved.theme, title: saved.creatorName.map { "By \($0)" } ?? "Custom Theme") {
                            Button("Delete", role: .destructive) { theme.removeSaved(saved.id) }
                        }
                    }
                    ForEach(accountOnly, id: \.self) { shared in
                        tile(shared, title: "Your Theme") {
                            Button("Save") { theme.save(shared, creatorName: nil) }
                        }
                    }
                }
            }
        }
        .task { model.sessionController.loadAccountCustomThemes() }
        .modal(item: $shareRequest) { request in
            ThemeShareSheet(theme: request.theme) { shareRequest = nil }
        }
    }

    /// The account's that are not kept here already.
    private var accountOnly: [SharedClientTheme] {
        (model.accountCustomThemes ?? []).filter { !theme.isSaved($0) }
    }

    private func tile(
        _ shared: SharedClientTheme, title: String, @ViewBuilder actions: () -> some View
    ) -> some View {
        ThemeTile(
            title: title,
            help: nil,
            isSelected: theme.choice == .shared(shared),
            ring: ring
        ) {
            theme.select(.shared(shared))
        } swatch: {
            SharedThemeSwatch(theme: shared)
        }
        .contextMenu {
            Button("Share\u{2026}") { shareRequest = ThemeShareRequest(theme: shared) }
                .disabled(model.connectionState != .ready)
            actions()
        }
    }
}
