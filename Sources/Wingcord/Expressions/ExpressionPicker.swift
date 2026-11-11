import SwiftUI
import WingcordCore

/// Emoji, stickers or GIFs — **one panel, opened on the tab of the control that
/// opened it**, with the system's capsule strip to move between the three
/// without closing it (POLISH-NOV decision 6, retiring "one mode per picker":
/// a GIF that turns out to be a sticker was a close, a click and a reopen).
/// Reaction and status pickers pass no tabs and stay emoji alone.
///
/// **Favorites and Frequently Used lead** the emoji and the sticker grids — the
/// account's own stars and uses from Discord's frecency settings, a right-click
/// away from starring (`AppModel.withUsageSections`).
///
/// **Everything floats and the grid runs underneath.** The rail and the search
/// field are glass bars the cells pass beneath, and the section heading is a
/// pill that holds under them as its section scrolls — sticky headers, with the
/// next section's pill shoving the last one out, which is the arrangement the
/// channel list already uses under the server pill.
///
/// The bars take **`.clear` glass, not `.regular`**. What passes under them is
/// emoji, server artwork and stickers — media — and `.regular` over media is
/// frost: it blurs the content away instead of lensing it, which is what makes
/// the bar read as a grey slab rather than as glass. See `INVARIANTS.md` §4.
///
/// **What is a view here and what is drawn.** The grid is an AppKit canvas —
/// nineteen hundred Unicode glyphs plus every custom emoji in the account is not
/// a number of view nodes anything survives. The chrome is a handful of controls
/// and stays SwiftUI, where it belongs.
///
/// The external-expression gate — which servers' emoji are usable from here — is
/// resolved against the store's **selected** channel, which is the channel the
/// composer that opened this is sitting over. See `AppModel.emojiCatalog`.
struct ExpressionPicker: View {
    var mode: ExpressionMode
    /// The section to open at — a stock sticker's pack, from its card's "View
    /// More Stickers". Nil opens where the picker always opens.
    var initialSectionID: String? = nil
    /// The tabs offered, in Discord's order (GIFs, Stickers, Emoji). Empty for
    /// a picker that does one thing — a reaction's, a status's.
    var tabs: [ExpressionMode] = []
    var onPick: (ExpressionItem) -> Void
    var onPickGIF: (GIF) -> Void
    /// Where a pick goes while the super reaction switch is on.
    ///
    /// **Set only by a reaction picker, for a reader who can send one** — its
    /// presence is what puts the switch in the search row, so the composer, a
    /// status and an account without Nitro never see a control that cannot
    /// work.
    var onPickSuperReaction: ((ExpressionItem) -> Void)? = nil
    /// **The channel a reaction is for**, when this picks one. A reaction is
    /// held to Discord's own rule — Fake Nitro sends a message's emoji as a
    /// link, but a reaction names the emoji — so its catalog locks what the
    /// account may not use there. Nil for everything that writes a message.
    var reactingIn: ChannelID? = nil

    init(
        mode: ExpressionMode,
        initialSectionID: String? = nil,
        tabs: [ExpressionMode] = [],
        onPick: @escaping (ExpressionItem) -> Void,
        onPickGIF: @escaping (GIF) -> Void,
        onPickSuperReaction: ((ExpressionItem) -> Void)? = nil,
        reactingIn: ChannelID? = nil
    ) {
        self.mode = mode
        self.initialSectionID = initialSectionID
        self.tabs = tabs
        self.onPick = onPick
        self.onPickGIF = onPickGIF
        self.onPickSuperReaction = onPickSuperReaction
        self.reactingIn = reactingIn
        _shown = State(initialValue: mode)
    }

    @Environment(AppModel.self) private var model
    /// The tab on show — the opening control's, until the strip moves it.
    @State private var shown: ExpressionMode
    @Environment(\.motion) private var motion
    /// The shared instance, held as `@State` so the view observes it — the same
    /// way every other surface that reads a preference does.
    @State private var settings = AppSettings.shared

    @State private var query = ""
    @State private var jump: ExpressionJump?
    @State private var jumpToken = 0
    @State private var topSection = 0
    /// What the pointer is over. Written by the grid on a change, never per
    /// frame — a hover moves at a person's pace.
    @State private var hover: ExpressionHover?
    /// What the floating chrome actually measures.
    ///
    /// **Measured, not summed.** The grid's content inset has to equal the
    /// chrome's height exactly or the first row hides behind the search field,
    /// and a hand-kept sum of five paddings is a number that drifts the first
    /// time any one of them changes. This is the one thing here worth a
    /// measurement — see `INVARIANTS.md` §2.
    @State private var chromeHeight: CGFloat = 0
    /// Whether every pick is a super reaction. Starts off each time the picker
    /// opens, as Discord's does.
    @State private var isSuperReaction = false

    /// The panel's size. A popover has no natural one, and a grid inside a
    /// container that sizes to its content has no width to lay out against.
    ///
    /// **Discord's** (Alex, 2026-10-15: "a bit bigger, its too small"): its
    /// picker opens 498 wide — the narrowest its drag handle allows,
    /// `expressionPickerWidth`'s `MIN` — and 486 tall with its tabs
    /// (`positionContainer`). It was 388 by 424 here.
    static let width: CGFloat = 498
    static let height: CGFloat = 486

    /// The rail's icon side. Here rather than inside the rail because the grid's
    /// top inset is derived from it, and the two must not drift.
    private static let railSide: CGFloat = 28

    private var catalog: ExpressionCatalog {
        switch shown {
        case .emoji:
            model.withUsageSections(
                reactingIn.map(model.reactionEmojiCatalog(in:)) ?? model.emojiCatalog,
                stickers: false,
                reacting: reactingIn != nil
            )
        case .stickers:
            model.withUsageSections(model.stickerCatalog, stickers: true, reacting: false)
        case .gifs: ExpressionCatalog()
        }
    }

    private var showsRail: Bool { !catalog.sections.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            if tabs.count > 1 { tabStrip }
            Group {
                if shown == .gifs {
                    GIFBoard(query: $query, onPick: onPickGIF).environment(model)
                } else {
                    gridTab
                }
            }
            .frame(maxHeight: .infinity)
            // Each tab arrives with its own grid and its own place in it.
            .id(shown)
            .transition(.opacity)
        }
        .frame(width: Self.width, height: Self.height)
        .animation(motion.standard, value: shown)
        // No background: the popover's own material IS the panel, and painting
        // over it is what turns liquid glass into a flat dark rectangle.
        .task(id: shown) {
            guard shown == .stickers else { return }
            await model.sessionController.loadDefaultStickerPacks()
            openInitialSection()
        }
        // The account's stars and uses, read once per session.
        .task { await model.sessionController.loadExpressionUsage() }
    }

    /// GIFs, Stickers, Emoji — the system's capsule strip, centred over the
    /// panel. Outside the floating chrome on purpose: the strip brings its own
    /// glass, and glass inside the chrome's container is glass on glass (§4).
    private var tabStrip: some View {
        SegmentedPicker(
            options: tabs.map { .init($0, $0.rawValue) },
            selection: Binding(
                get: { shown },
                set: { next in
                    guard next != shown else { return }
                    query = ""
                    hover = nil
                    topSection = 0
                    jump = nil
                    shown = next
                }
            )
        )
        .frame(maxWidth: .infinity)
        .padding(.top, Spacing.base)
        .padding(.bottom, Spacing.tight)
    }

    /// Jumps to `initialSectionID`, once the packs it names are in the catalog.
    private func openInitialSection() {
        guard let initialSectionID, query.isEmpty,
              let index = catalog.sections.firstIndex(where: { $0.id == initialSectionID })
        else { return }
        jumpToken += 1
        jump = ExpressionJump(section: index, token: jumpToken)
        topSection = index
    }

    private var gridTab: some View {
        // Resolved once and handed to both the rail and the grid: they are one
        // control showing the same list twice, and computing it twice is a
        // second pass over the account's whole emoji set.
        let sections = catalog.filtered(by: query)

        return ZStack(alignment: .top) {
            if sections.isEmpty {
                emptyState
            } else {
                ExpressionGridView(
                    sections: sections,
                    mode: shown,
                    topInset: chromeHeight,
                    // Reduce Motion is resolved once at the root and read from
                    // the environment; the app's own preference sits beside it.
                    animates: settings.playsAnimatedMedia && !motion.reduceMotion,
                    // A search result set is one flat section; jumping into it
                    // has no meaning and would fight the reader's scroll.
                    jump: query.isEmpty ? jump : nil,
                    onPick: isSuperReaction ? (onPickSuperReaction ?? onPick) : onPick,
                    onTopSectionChange: { topSection = $0 },
                    onHover: { hover = $0 },
                    isFavorite: { model.isFavorite($0) },
                    onToggleFavorite: { model.toggleFavorite($0) }
                )
            }
            chrome
            footer
        }
    }

    /// What the pointer is over: its shortcode, and the server it came from.
    ///
    /// **Present only while something is hovered**, and it takes no space when
    /// it is not — a permanent strip at the foot of a small panel is a row of
    /// emoji spent on a caption that is usually empty. It floats over the grid
    /// like the chrome above it, so nothing reflows when it appears.
    @ViewBuilder
    private var footer: some View {
        if let hover {
            HStack(spacing: Spacing.base) {
                art(hover.art)
                    .frame(width: Metrics.control, height: Metrics.control)

                VStack(alignment: .leading, spacing: 0) {
                    Text(hover.hasShortcode ? ":\(hover.name):" : hover.name)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(Ink.primary)
                        .lineLimit(1)
                    Text("from \(hover.source)")
                        .font(.system(.caption2))
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
                badge(hover.sourceBadge, side: 20)
            }
            .padding(.horizontal, Spacing.snug)
            .padding(.vertical, Spacing.tight)
            .chromeOverMedia(in: .rect(cornerRadius: Radius.glass, style: .continuous))
            .padding(.horizontal, Spacing.snug)
            .padding(.bottom, Spacing.snug)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .transition(.opacity)
            .animation(motion.fadeQuick, value: hover)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func art(_ art: ExpressionItem.Art) -> some View {
        switch art {
        case .glyph(let glyph):
            Text(glyph).font(.system(.title))
        case .image(let url, let animated):
            // The still, with the film over it — the same stack the grid uses,
            // and the only way a Lottie sticker shows anything here at all,
            // since it has no still to fall back on.
            Color.clear
                .overlay { RemoteImage(url: url, side: Metrics.control) { Color.clear } }
                .overlay {
                    if animated, let url {
                        AnimatedDecoration(
                            url: url,
                            side: Metrics.control
                        )
                    }
                }
        }
    }

    @ViewBuilder
    private func badge(_ badge: ExpressionSection.Badge, side: CGFloat) -> some View {
        switch badge {
        case .glyph(let glyph):
            Text(glyph).font(.system(size: side * 0.8))
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: side * 0.62, weight: .semibold))
                .foregroundStyle(Ink.secondary)
        case .image(let url, let monogram):
            RemoteImage(url: url, side: side) {
                Text(monogram)
                    .font(.system(.caption2, weight: .bold))
                    .foregroundStyle(Ink.secondary)
                    .frame(width: side, height: side)
                    .background(Palette.surfaceRaised)
            }
            .frame(width: side, height: side)
            .clipShape(.rect(cornerRadius: 6, style: .continuous))
        }
    }

    /// The rail and the field, as one glass assembly over the grid.
    ///
    /// **One `GlassEffectContainer` around both.** Two adjacent glass surfaces
    /// rendered independently double the material where they meet, which is the
    /// stacking `INVARIANTS.md` §4 forbids. Merged, the system renders them as
    /// one piece of material carrying two shapes.
    private var chrome: some View {
        GlassEffectContainer(spacing: Spacing.base) {
            VStack(spacing: Spacing.base) {
                if showsRail {
                    ExpressionRail(
                        sections: catalog.sections,
                        selection: topSection,
                        side: Self.railSide,
                        onSelect: { index in
                            // The token is what makes a repeat click a new
                            // request: the same index twice is the same value,
                            // and a value cannot express "again".
                            jumpToken += 1
                            jump = ExpressionJump(section: index, token: jumpToken)
                            topSection = index
                        }
                    )
                }
                searchRow
            }
            .padding(.horizontal, Spacing.snug)
            .padding(.top, Spacing.base)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            // A `@State` write of an equal value still invalidates, and this
            // fires on every layout pass.
            guard abs(chromeHeight - height) > 0.5 else { return }
            chromeHeight = height
        }
    }

    private var searchRow: some View {
        HStack(spacing: Spacing.base) {
            HStack(spacing: Spacing.base) {
                Image(systemName: "magnifyingglass")
                    .font(.system(.subheadline))
                    .foregroundStyle(Ink.tertiary)

                TextField(
                    isSuperReaction ? "Search Super Reactions" : shown.searchPlaceholder,
                    text: $query
                )
                    .textFieldStyle(.plain)
                    .font(.system(.subheadline))

                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(.subheadline))
                            .foregroundStyle(Ink.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, Spacing.snug)
            .frame(minHeight: Metrics.control)
            .chromeOverMedia()

            if onPickSuperReaction != nil { superReactionSwitch }
            if shown == .emoji { skinTone }
        }
    }

    /// The super reaction switch — between the field and the skin tone, where
    /// Discord puts it.
    ///
    /// **Its state is in its material**: accent-tinted glass while every pick
    /// will be a super reaction, plain while none will, so the picker says
    /// which it is doing without the tooltip. The mark turns a full circle on
    /// each change, as Discord's does, and holds still under Reduce Motion.
    private var superReactionSwitch: some View {
        Button { isSuperReaction.toggle() } label: {
            SuperReactionGlyph()
                .foregroundStyle(isSuperReaction ? Color.white : InkColor.secondary)
                .frame(width: 16, height: 16)
                .rotationEffect(.degrees(isSuperReaction && !motion.reduceMotion ? 360 : 0))
                .frame(width: Metrics.control, height: Metrics.control)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(
            isSuperReaction
                ? .regular.tint(Palette.accent.opacity(0.7)).interactive()
                : .regular.interactive(),
            in: .circle
        )
        .animation(motion.glassMorph, value: isSuperReaction)
        .help(isSuperReaction ? "Super Reactions enabled" : "Enable Super Reactions")
        .accessibilityLabel("Super Reaction")
        .accessibilityValue(isSuperReaction ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }

    /// The tone every emoji that takes one is drawn in.
    ///
    /// A menu rather than a row of six swatches: the row is what a *touch*
    /// picker needs, because a menu is awkward under a thumb. A pointer has no
    /// such problem, and six controls where one will do is five controls of
    /// permanent chrome.
    private var skinTone: some View {
        Menu {
            ForEach(UnicodeEmoji.SkinTone.allCases) { tone in
                Button("\(tone.swatch)  \(tone.title)") { settings.skinTone = tone }
            }
        } label: {
            Text(settings.skinTone.swatch)
                .font(.system(.title3))
                .frame(width: Metrics.control, height: Metrics.control)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .interactiveChromeOverMedia(in: .circle)
        .animation(motion.glassMorph, value: settings.skinTone)
        .help("Skin tone")
        .accessibilityLabel("Skin tone: \(settings.skinTone.title)")
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            Text(query.isEmpty ? "Nothing here yet" : "No results for “\(query)”")
                .font(.system(.subheadline))
                .foregroundStyle(Ink.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - The rail

/// One icon per section: a server's artwork, or a Unicode category's glyph.
///
/// **Two-way with the grid.** Clicking jumps the grid; scrolling the grid moves
/// the selection here and scrolls the rail to keep it on screen. The two are one
/// control showing the same position twice — a rail that only leads is one that
/// silently disagrees with what is on screen.
private struct ExpressionRail: View {
    var sections: [ExpressionSection]
    var selection: Int
    var side: CGFloat
    var onSelect: (Int) -> Void

    @Environment(\.motion) private var motion

    var body: some View {
        ScrollViewReader { rail in
            ScrollView(.horizontal) {
                HStack(spacing: Spacing.tight) {
                    ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                        icon(section, index: index).id(index)
                    }
                }
                .padding(.horizontal, Spacing.base)
                .padding(.vertical, Spacing.base)
            }
            .scrollIndicators(.never)
            .frame(height: side + Spacing.base * 2)
            .chromeOverMedia()
            .onChange(of: selection) { _, index in
                withAnimation(motion.standard) { rail.scrollTo(index, anchor: .center) }
            }
        }
    }

    private func icon(_ section: ExpressionSection, index: Int) -> some View {
        let isSelected = index == selection

        return Button { onSelect(index) } label: {
            badge(section.badge)
                .frame(width: side, height: side)
                // Squircle at rest, rounder when selected — the shape language
                // the guild rail already uses, so a server looks like the same
                // object in both places.
                .clipShape(.rect(cornerRadius: isSelected ? 8 : 13, style: .continuous))
                // Dimmed, not removed: the section is still worth looking at,
                // and a rail that omits servers reads as those servers having
                // nothing in them.
                .opacity(section.isLocked ? 0.4 : 1)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .animation(motion.standard, value: isSelected)
        .help(section.title)
        .accessibilityLabel(Text(section.title))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    @ViewBuilder
    private func badge(_ badge: ExpressionSection.Badge) -> some View {
        switch badge {
        case .glyph(let glyph):
            Text(glyph)
                .font(.system(size: side * 0.66))
                .frame(width: side, height: side)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: side * 0.5, weight: .semibold))
                .foregroundStyle(Ink.secondary)
                .frame(width: side, height: side)
        case .image(let url, let monogram):
            // Static, never animated: a rail can hold a hundred servers, and
            // animating all of them costs the same as animating the grid.
            RemoteImage(url: url, side: side) {
                Text(monogram)
                    .font(.system(.caption2, weight: .bold))
                    .foregroundStyle(Ink.secondary)
                    .frame(width: side, height: side)
                    .background(Palette.surfaceRaised)
            }
        }
    }
}
