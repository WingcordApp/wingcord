import SwiftUI
import WingcordCore

/// The server's front page: who welcomed you, what to do first, and what to
/// read — redesigned as a welcome poster (Alex, 2026-11-18: "i want smth cool
/// nice and beautiful", picked over a settings-style list and a journey).
///
/// **Everything on it is either the server's own content or a fact about it.**
/// The banner — or, without one, a gradient drawn from the server's own icon
/// — the icon and an action's emoji are the server's colour; the chrome around
/// them is achromatic, with the accent for what is open and for the rules.
///
/// **A channel opens beside the page** (his pick): every row puts its channel
/// in the column next to the guide, so the reader keeps their place and can
/// read several in turn; the column's Open Channel goes all the way.
struct ServerGuideContainer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let presentation = model.serverGuidePresentation {
                ServerGuidePane(
                    presentation: presentation,
                    previewedChannelID: model.previewedChannelID,
                    previewChannel: { model.previewChannel($0) },
                    openRules: { model.openServerRules(inGuild: presentation.guildID) }
                )
                .equatable()
            }
        }
        // The rules are the one thing on this page that is not on its own route,
        // and they are asked for only by somebody who has opened the page.
        // Asking with the guild would spend a request per server visited on a
        // row most servers do not have.
        .task(id: model.selectedGuildID) {
            guard let guildID = model.selectedGuildID else { return }
            model.sessionController.loadMemberVerification(guildID)
        }
    }
}

struct ServerGuidePane: View, Equatable {
    var presentation: ServerGuidePresentation
    /// Which channel, if any, is open in the column beside this page.
    var previewedChannelID: ChannelID?

    static func == (lhs: ServerGuidePane, rhs: ServerGuidePane) -> Bool {
        lhs.presentation == rhs.presentation
            && lhs.previewedChannelID == rhs.previewedChannelID
    }

    var previewChannel: (ChannelID) -> Void = { _ in }
    var openRules: () -> Void = {}

    /// The page settles in once, section by section — see `SurfaceEntrance`.
    @State private var hasAppeared = false

    var body: some View {
        // **The whole column, not a reading measure** (Alex, 2026-11-18: "i
        // was imagining the server guide to fill this whole space"): a front
        // page, not an article.
        SurfacePage(measure: .infinity) {
            GuidePosterHero(presentation: presentation)
                .modifier(SurfaceEntrance(index: 0, isShown: hasAppeared))
            if presentation.isLoading && !presentation.hasContent {
                SurfaceLoadingState(message: "Loading the server guide…")
            } else if !presentation.hasContent {
                SurfaceEmptyState(
                    symbol: "signpost.right",
                    title: "No guide yet",
                    detail: "This server has not written one."
                )
            } else {
                // **The gate comes first, and only while it is one.** Somebody
                // who joined elsewhere and never agreed can read this server and
                // not speak in it, and nothing else on screen says so.
                if presentation.isPendingMember && presentation.hasRules {
                    PendingRulesBanner(action: openRules)
                        .modifier(SurfaceEntrance(index: 1, isShown: hasAppeared))
                }
                if let welcome = presentation.welcome {
                    WelcomeBubble(welcome: welcome)
                        .modifier(SurfaceEntrance(index: 2, isShown: hasAppeared))
                }
                if !presentation.actions.isEmpty || presentation.hasRules {
                    GuideSection(title: "Get Started") {
                        // As many across as the column holds: two in a narrow
                        // window, four in a wide one.
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 240), spacing: Spacing.margin, alignment: .top)],
                            spacing: Spacing.margin
                        ) {
                            ForEach(presentation.actions) { row in
                                GuideActionCard(
                                    row: row,
                                    isOpen: previewedChannelID == row.channelID,
                                    act: previewChannel
                                )
                            }
                            if presentation.hasRules {
                                // **It goes to the rules channel**, like every
                                // other card — the sheet is the fallback for a
                                // server with rules and no channel to read
                                // them in.
                                GuideRulesCard(
                                    channelName: presentation.rulesChannelName,
                                    channelSymbolName: presentation.rulesChannelSymbolName,
                                    action: openRules
                                )
                            }
                        }
                    }
                    .modifier(SurfaceEntrance(index: 3, isShown: hasAppeared))
                }
                if !presentation.resources.isEmpty {
                    GuideSection(title: "Resources") {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 380), spacing: Spacing.margin, alignment: .top)],
                            spacing: Spacing.margin
                        ) {
                            ForEach(presentation.resources) { row in
                                GuideResourceCard(
                                    row: row,
                                    isOpen: previewedChannelID == row.channelID,
                                    act: previewChannel
                                )
                            }
                        }
                    }
                    .modifier(SurfaceEntrance(index: 4, isShown: hasAppeared))
                }
            }
        }
        .onAppear { hasAppeared = true }
    }
}

// MARK: - Motion

/// A card's lift under the pointer, shared by every card on the page.
private struct GuideCardChrome: ViewModifier {
    var isHovered: Bool
    var isOpen: Bool
    var cornerRadius: CGFloat = GuideMetrics.cardCorner

    @Environment(\.motion) private var motion

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(isOpen ? Palette.accent.opacity(0.12) : Color.white.opacity(isHovered ? 0.08 : 0.05))
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        isOpen ? Palette.accent.opacity(0.8) : Palette.edge,
                        lineWidth: isOpen ? 1.5 : 1
                    )
                    .allowsHitTesting(false)
            }
            .scaleEffect(isHovered && !motion.reduceMotion ? 1.012 : 1)
            .shadow(
                color: .black.opacity(isHovered ? 0.28 : 0.12),
                radius: isHovered ? 16 : 6,
                y: isHovered ? 8 : 3
            )
            .animation(motion.hover, value: isHovered)
            .animation(motion.standard, value: isOpen)
    }
}

private enum GuideMetrics {
    static let cardCorner: CGFloat = 20
    static let glyphWell: CGFloat = 60
    /// The glyph inside its well, up from the surface kit's 26.
    static let glyphScale: CGFloat = 1.3
}

// MARK: - The head of the page

/// The server as a poster: its banner across the head — or a gradient drawn
/// from its own icon where it has none, never a dark slab — the icon large and
/// centred over the banner's edge, the name and its mark under it, and the
/// member counts as pills.
///
/// The banner is `Color.clear` with the picture as an **overlay**, never as a
/// sibling: an aspect-filled image reports the image's size to layout and takes
/// the column with it — the trap `SidebarBanner` and the full profile both
/// already document.
private struct GuidePosterHero: View {
    var presentation: ServerGuidePresentation

    private static let bannerHeight: CGFloat = 300
    private static let iconSide: CGFloat = 128
    /// How far the icon hangs below the artwork.
    private static let iconDrop: CGFloat = 58
    /// The ring of page ground cut around the icon.
    private static let ring: CGFloat = 8

    var body: some View {
        VStack(spacing: Spacing.snug) {
            ZStack(alignment: .bottom) {
                banner
                icon.offset(y: Self.iconDrop)
            }
            .padding(.bottom, Self.iconDrop)
            identity
        }
        .frame(maxWidth: .infinity)
    }

    private var banner: some View {
        Color.clear
            .frame(height: Self.bannerHeight)
            .overlay {
                if let bannerURL = presentation.bannerURL {
                    RemoteImage(url: bannerURL, side: Proportions.surfaceColumnMax, bucket: .artwork) {
                        GuideBannerArt(iconURL: presentation.iconURL)
                    }
                    .aspectRatio(contentMode: .fill)
                } else {
                    GuideBannerArt(iconURL: presentation.iconURL)
                }
            }
            .overlay {
                // Depth at the foot, where the icon sits.
                LinearGradient(
                    colors: [.clear, .black.opacity(0.28)],
                    startPoint: .center,
                    endPoint: .bottom
                )
            }
            .clipShape(.rect(cornerRadius: GuideMetrics.cardCorner + 4, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: GuideMetrics.cardCorner + 4, style: .continuous)
                    .strokeBorder(Palette.edge, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            // The gap around the icon is a **hole** in the artwork rather than a
            // stroke over it, so what shows through is the page's own ground.
            .mask(alignment: .bottom) { iconHole }
    }

    private var iconHole: some View {
        Rectangle()
            .overlay(alignment: .bottom) {
                RoundedRectangle(cornerRadius: (Self.iconSide + Self.ring * 2) * 0.3, style: .continuous)
                    .frame(width: Self.iconSide + Self.ring * 2, height: Self.iconSide + Self.ring * 2)
                    .offset(y: Self.iconDrop + Self.ring)
                    .blendMode(.destinationOut)
            }
            .compositingGroup()
    }

    private var icon: some View {
        RemoteImage(url: presentation.iconURL, side: Self.iconSide) {
            Text(presentation.monogram)
                .font(.system(size: Self.iconSide * 0.3, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: Self.iconSide, height: Self.iconSide)
                .background { GuideBannerArt(iconURL: nil) }
        }
        .frame(width: Self.iconSide, height: Self.iconSide)
        .clipShape(.rect(cornerRadius: Self.iconSide * 0.3, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 16, y: 8)
    }

    private var identity: some View {
        VStack(spacing: Spacing.base) {
            HStack(spacing: Spacing.base) {
                Text(presentation.name)
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(Ink.primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                if let mark = presentation.mark {
                    // **Sized to the title it stands beside** (Alex, 2026-11-18,
                    // Image 200): the badge's own 18 points sat at half the
                    // height of a 34-point name, as Discord's never does.
                    GuildMarkBadge(mark: mark, side: 28)
                }
            }
            HStack(spacing: Spacing.base) {
                if let count = presentation.memberCount {
                    GuidePill(dot: Ink.tertiary, text: "\(count.formatted(.number)) members")
                }
                if let online = presentation.onlineCount {
                    GuidePill(dot: Palette.presenceOnline, text: "\(online.formatted(.number)) online")
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// A fact about the server, as a pill: a coloured dot and its words.
private struct GuidePill: View {
    var dot: Color
    var text: String

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(dot).frame(width: 8, height: 8)
            Text(text)
                .font(.system(.callout, weight: .medium))
                .foregroundStyle(Ink.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, Spacing.snug + 2)
        .frame(height: 32)
        .background(Color.white.opacity(0.06), in: .capsule)
        .overlay { Capsule().strokeBorder(Palette.edge, lineWidth: 1) }
    }
}

/// A server with no banner gets one made of its own icon: the icon's colours
/// spread across a mesh, softly lit from the top corner — the server's colour,
/// never a flat dark slab. Without an icon, the accent's.
private struct GuideBannerArt: View {
    var iconURL: URL?

    @State private var swatches: [Color] = []

    var body: some View {
        let colours = Self.three(swatches)
        MeshGradient(
            width: 3,
            height: 2,
            points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 1], [0.55, 1], [1, 1],
            ],
            colors: [
                colours[0], colours[1], colours[2],
                colours[1].mix(with: .black, by: 0.45),
                colours[2].mix(with: .black, by: 0.35),
                colours[0].mix(with: .black, by: 0.5),
            ]
        )
        .overlay {
            RadialGradient(
                colors: [.white.opacity(0.18), .clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 420
            )
        }
        .animation(.easeOut(duration: 0.35), value: swatches)
        .task(id: iconURL) {
            swatches = await Self.swatches(for: iconURL)
        }
    }

    private static func three(_ swatches: [Color]) -> [Color] {
        let accent = Palette.accent
        var colours = swatches
        let fallback = [accent, accent.mix(with: .purple, by: 0.5), accent.mix(with: .black, by: 0.3)]
        while colours.count < 3 { colours.append(fallback[colours.count]) }
        return colours
    }

    /// The icon's most significant colours, from a small decode.
    private static func swatches(for url: URL?) async -> [Color] {
        guard let url,
              let image = await ImageStore.shared.image(
                  for: ImageStore.Key(url: url, maximumPixelSize: 64),
                  bucket: .thumbnail
              )
        else { return [] }
        return ProfileThemePalette.palette(of: image).prefix(3).map { swatch in
            Color(
                red: Double(swatch.x) / 255,
                green: Double(swatch.y) / 255,
                blue: Double(swatch.z) / 255
            )
        }
    }
}

// MARK: - The welcome

/// The sentence somebody in the server wrote to whoever arrives, as a message
/// from them: their face, their name — and the crown the group-DM owner gets,
/// for the same reason — and the words in a bubble pointing back at them.
private struct WelcomeBubble: View {
    var welcome: ServerGuidePresentation.Welcome

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.snug) {
            AvatarView(url: welcome.avatarURL, monogram: welcome.authorMonogram, side: 48)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(welcome.authorName)
                        .font(.system(.body, weight: .semibold))
                        .foregroundStyle(Ink.primary)
                        .lineLimit(1)
                    if welcome.isOwner {
                        Image(systemName: "crown.fill")
                            .font(.system(.caption))
                            .foregroundStyle(Palette.presenceIdle)
                            .accessibilityLabel("Server owner")
                    }
                }
                Text(welcome.message)
                    .font(.system(size: 15))
                    .foregroundStyle(Ink.primary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .background {
                        UnevenRoundedRectangle(
                            topLeadingRadius: 6,
                            bottomLeadingRadius: 20,
                            bottomTrailingRadius: 20,
                            topTrailingRadius: 20,
                            style: .continuous
                        )
                        .fill(Color.white.opacity(0.07))
                    }
                    .overlay {
                        UnevenRoundedRectangle(
                            topLeadingRadius: 6,
                            bottomLeadingRadius: 20,
                            bottomTrailingRadius: 20,
                            topTrailingRadius: 20,
                            style: .continuous
                        )
                        .strokeBorder(Palette.edge, lineWidth: 1)
                    }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Sections and cards

private struct GuideSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            Text(title)
                .font(.system(.title2, weight: .semibold))
                .foregroundStyle(Ink.primary)
                .padding(.horizontal, Spacing.tight)
            content
        }
    }
}

/// Where a card leads: the channel's glyph and its name, as a chip.
private struct ChannelChip: View {
    var name: String
    var symbolName: String

    var body: some View {
        HStack(spacing: 4) {
            Image(symbol: symbolName)
                .font(.system(.caption, weight: .semibold))
            Text(name)
                .font(.system(.caption, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(Ink.secondary)
        .padding(.horizontal, Spacing.base)
        .frame(height: 22)
        .background(Color.white.opacity(0.07), in: .capsule)
    }
}

/// One step of Get Started: the emoji in a tinted well, what to do, and where.
///
/// **Only a button when it leads somewhere.** A guide can name a channel the
/// reader may not see, and a card that stops at the permission check is the
/// inert control §5.5 forbids.
private struct GuideActionCard: View {
    var row: ServerGuidePresentation.Row
    /// Whether its channel is the one open beside the page.
    var isOpen: Bool
    var act: (ChannelID) -> Void

    @State private var isHovered = false
    @Environment(\.motion) private var motion

    var body: some View {
        Button { act(row.channelID) } label: {
            VStack(alignment: .leading, spacing: Spacing.snug) {
                if case .picture(let url) = row.glyph {
                    // The server's own picture fills the well, as Discord's does.
                    RemoteImage(url: url, side: GuideMetrics.glyphWell) { Color.white.opacity(0.08) }
                        .frame(width: GuideMetrics.glyphWell, height: GuideMetrics.glyphWell)
                        .clipShape(Circle())
                } else {
                    SurfaceGlyphView(glyph: row.glyph)
                        .scaleEffect(GuideMetrics.glyphScale)
                        .frame(width: GuideMetrics.glyphWell, height: GuideMetrics.glyphWell)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                Text(row.title)
                    .font(.system(.title3, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let name = row.channelName {
                    ChannelChip(name: name, symbolName: row.channelSymbolName)
                }
            }
            .padding(Spacing.margin)
            .frame(maxWidth: .infinity, minHeight: 176, alignment: .topLeading)
            .overlay(alignment: .topTrailing) { doneMark }
            .modifier(GuideCardChrome(isHovered: isHovered, isOpen: isOpen))
            .contentShape(.rect(cornerRadius: GuideMetrics.cardCorner, style: .continuous))
        }
        .buttonStyle(ActivityPressStyle())
        .disabled(row.channelName == nil)
        .onHover { isHovered = $0 && row.channelName != nil }
        .accessibilityLabel(Text(row.title))
        .accessibilityValue(Text(accessibilityValue))
    }

    /// Discord's check or empty ring (`283012`): done, or still to do.
    @ViewBuilder
    private var doneMark: some View {
        if let isDone = row.isDone {
            Group {
                if isDone {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color(red: 0.14, green: 0.64, blue: 0.35))
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                } else {
                    Image(systemName: "circle")
                        .foregroundStyle(Ink.tertiary)
                }
            }
            .font(.system(size: 22, weight: .regular))
            .padding(Spacing.margin)
            .animation(motion.standard, value: isDone)
            .accessibilityHidden(true)
        }
    }

    private var accessibilityValue: String {
        let status = row.isDone.map { $0 ? "Completed. " : "Not completed. " } ?? ""
        return status + (row.channelName.map { "Opens \($0)" } ?? "")
    }
}

/// Read the rules: the one card in the accent, because it is the one the
/// server asks of everybody.
private struct GuideRulesCard: View {
    var channelName: String?
    var channelSymbolName: String
    var action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Spacing.snug) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                    .frame(width: GuideMetrics.glyphWell, height: GuideMetrics.glyphWell)
                    .background(Circle().fill(Palette.accent.opacity(0.16)))
                Text("Read the rules")
                    .font(.system(.title3, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                Spacer(minLength: 0)
                if let channelName {
                    ChannelChip(name: channelName, symbolName: channelSymbolName)
                }
            }
            .padding(Spacing.margin)
            .frame(maxWidth: .infinity, minHeight: 176, alignment: .topLeading)
            .modifier(GuideCardChrome(isHovered: isHovered, isOpen: false))
            .contentShape(.rect(cornerRadius: GuideMetrics.cardCorner, style: .continuous))
        }
        .buttonStyle(ActivityPressStyle())
        .onHover { isHovered = $0 }
        .accessibilityLabel(Text("Read the rules"))
    }
}

/// A resource: its glyph in a tinted well, its title and what it is, and the
/// channel — wide, because a resource has a sentence to say.
private struct GuideResourceCard: View {
    var row: ServerGuidePresentation.Row
    var isOpen: Bool
    var act: (ChannelID) -> Void

    @State private var isHovered = false

    var body: some View {
        Button { act(row.channelID) } label: {
            HStack(alignment: .center, spacing: Spacing.margin) {
                if case .picture(let url) = row.glyph {
                    // The server's own picture — Rockstar's R★ — filling the
                    // well, as Discord's thumbnail does.
                    RemoteImage(url: url, side: 64) { Color.white.opacity(0.08) }
                        .frame(width: 64, height: 64)
                        .clipShape(.rect(cornerRadius: 14, style: .continuous))
                } else {
                    SurfaceGlyphView(glyph: row.glyph)
                        .scaleEffect(GuideMetrics.glyphScale)
                        .frame(width: 64, height: 64)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                        )
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(row.title)
                        .font(.system(.title3, weight: .semibold))
                        .foregroundStyle(Ink.primary)
                        .lineLimit(1)
                    if let detail = row.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.system(.subheadline))
                            .foregroundStyle(Ink.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    if let name = row.channelName {
                        ChannelChip(name: name, symbolName: row.channelSymbolName)
                    }
                }
                Spacer(minLength: Spacing.base)
                Image(systemName: isOpen ? "sidebar.right" : "chevron.right")
                    .font(.system(.body, weight: .semibold))
                    .foregroundStyle(isOpen ? Palette.accent : Ink.tertiary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(Spacing.margin)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(GuideCardChrome(isHovered: isHovered, isOpen: isOpen))
            .contentShape(.rect(cornerRadius: GuideMetrics.cardCorner, style: .continuous))
        }
        .buttonStyle(ActivityPressStyle())
        .disabled(row.channelName == nil)
        .onHover { isHovered = $0 && row.channelName != nil }
        .accessibilityLabel(Text(row.title))
        .accessibilityHint(Text(row.detail ?? ""))
    }
}

/// Shown while the reader has joined and not yet agreed to the rules.
///
/// Accent-tinted rather than destructive: nothing is wrong, there is one thing
/// left to do — and `Palette.destructive` is reserved for what it says it is.
private struct PendingRulesBanner: View {
    var action: () -> Void

    var body: some View {
        HStack(spacing: Spacing.snug) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(.title3))
                .foregroundStyle(Palette.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("Agree to the rules to join in")
                    .font(.system(.body, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                Text("You can read this server, but you cannot post until you do.")
                    .font(.system(.caption))
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Spacing.base)
            SurfaceFilledButton(title: "Read & Agree", systemImage: nil, action: action)
        }
        .padding(Spacing.margin)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: GuideMetrics.cardCorner, style: .continuous)
                .fill(Palette.accent.opacity(0.14))
        }
        .overlay {
            RoundedRectangle(cornerRadius: GuideMetrics.cardCorner, style: .continuous)
                .strokeBorder(Palette.accent.opacity(0.45), lineWidth: 1)
        }
    }
}
