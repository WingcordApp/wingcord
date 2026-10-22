import SwiftUI
import WingcordCore

/// The editor's rail: the cosmetics that cannot be edited in place.
///
/// **Additive, not a replacement.** The sheet grows by this width when the
/// editor opens rather than the rail displacing the identity panel — measured on
/// Discord's own, whose modal goes from 961 points to 1,195 when the rail
/// appears, which is the rail's width and nothing else. The profile you are
/// editing has to stay whole beside the controls that change it, or the preview
/// is not a preview.
///
/// **Everything here is a thing you cannot type.** A bio, a name and a pronoun
/// are edited on the profile itself — see `ProfileSheet`'s editing mode — and
/// what is left is the four cosmetics and the banner colour, each of which is a
/// grid of artwork behind a sheet.
struct ProfileEditRail: View {
    var editor: ProfileEditor
    var profile: ProfilePresentation
    /// The servers whose per-server profile the reader could switch to, in the
    /// scope menu. Empty leaves the menu a plain label.
    var scopes: [ProfileEditScope]
    var selectScope: (ProfileEditScope) -> Void
    var collapse: () -> Void

    @Environment(\.motion) private var motion
    @Environment(AppModel.self) private var model
    @Environment(ProfileFlyouts.self) private var flyouts: ProfileFlyouts?

    /// Raises a tile's flyout, hung off the tile.
    private func present(_ picker: ProfileEditPicker) {
        flyouts?.show(picker, from: .rail)
    }

    /// Discord's 231-point rail, scaled by the ratio between their identity card
    /// and ours — 360 ÷ 400 — because the rail's job is to sit beside that card
    /// in proportion, not to be a fixed strip.
    static let width: CGFloat = 210
    private static let gutter: CGFloat = 16

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Palette.railHairline)
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.group) {
                    if capability.cosmeticsLocked { serverLock }
                    ForEach(sections) { section in
                        railSection(section)
                            .disabled(isLocked(section))
                            .opacity(isLocked(section) ? 0.45 : 1)
                    }
                }
                .padding(.horizontal, Self.gutter)
                .padding(.vertical, Spacing.margin)
                .frame(width: Self.width, alignment: .leading)
            }
            .scrollIndicators(.never)
            .softScrollEdgesVertical()
            nitroFooter
        }
        .frame(width: Self.width)
        .background(Palette.surface)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Palette.railHairline).frame(width: 1)
        }
    }

    // MARK: The scope

    private var header: some View {
        HStack(spacing: Spacing.base) {
            scopeMenu
                // First claim on the row: the name truncates inside the pill
                // rather than the pill spilling past the rail.
                .layoutPriority(1)
            Spacer(minLength: 0)
            Button(action: collapse) {
                Image(systemName: "chevron.right.2")
                    .font(.system(.body, weight: .semibold))
                    .foregroundStyle(InkColor.secondary)
                    .frame(width: Metrics.control, height: Metrics.control)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Hide the editor")
            .accessibilityLabel(Text("Hide the editor"))
        }
        .padding(.horizontal, Self.gutter)
        .frame(height: 52)
    }

    @ViewBuilder
    private var scopeMenu: some View {
        // **No switcher for one scope.** A picker with a single entry is a
        // label that looks pressable — the same rule the profile's own tab
        // strip follows.
        if scopes.count > 1 {
            ProfileScopeSwitcher(
                scopes: scopes,
                current: currentScope,
                isLocked: editor.isDirty,
                select: selectScope
            )
        } else {
            Text(currentScope.title)
                .font(.system(.body, weight: .semibold))
                .foregroundStyle(InkColor.primary)
                .lineLimit(1)
        }
    }

    private var currentScope: ProfileEditScope {
        scopes.first { $0.scope == editor.scope } ?? .main
    }

    // MARK: The sections

    /// What the rail offers, which is **not the same list per scope**.
    ///
    /// **A row is here only when the whole path behind it works** — a flyout
    /// to choose in and a route to save with. The frame joined the effect once
    /// Discord's own save was read: both are the profile's collectibles,
    /// `collectibles_sku_ids` (build 643186).
    ///
    /// What this account and this server actually permit — see
    /// `ProfileEditCapability`, where every gate is quoted from Discord's own
    /// parameter tables.
    private var capability: ProfileEditCapability {
        model.profileEditCapability(for: editor.scope)
    }

    private var sections: [RailSection] {
        switch editor.scope {
        // **The server tag is not in the rail.** It lives beside the handle on
        // the card itself, where the thing it changes actually appears — a
        // control belongs next to what it affects, and a tag is worn on the
        // name rather than being a cosmetic in a grid. See `ServerTagChooser`.
        case .account: [.nameplate, .avatar, .banner, .colours, .effectAndFrame, .displayNameStyle, .typingIndicator]
        // **A server's profile carries its own of each**, on the two routes
        // Discord splits it over — see `ProfileEditor.saveGuild`. There is no
        // per-server typing indicator.
        case .guild: [.nameplate, .avatar, .banner, .colours, .effectAndFrame, .displayNameStyle]
        }
    }

    /// Whether a section is dimmed and inert — **everything, in a server,
    /// without Nitro** (Discord's own rule: a nickname and pronouns only), and
    /// the banner on an account without it.
    private func isLocked(_ section: RailSection) -> Bool {
        if capability.cosmeticsLocked { return true }
        switch section {
        case .banner: return !capability.canEditCurrentBanner
        case .effectAndFrame: return !capability.canEditCurrentEffect
        default: return false
        }
    }

    /// Said once, at the top, rather than under every tile.
    private var serverLock: some View {
        Label(ProfileEditCapability.serverProfileNote, systemImage: "lock.fill")
            .font(.system(.caption, weight: .medium))
            .foregroundStyle(InkColor.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(Spacing.snug)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: Radius.chip, style: .continuous))
    }

    @ViewBuilder
    private func railSection(_ section: RailSection) -> some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            HStack(spacing: Spacing.tight) {
                Text(title(for: section))
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(InkColor.primary)
                // **Marked, not removed.** A section that vanishes on a free
                // account reads as the app lacking the feature; Discord shows
                // the row and says who it is for.
                if !permits(section) {
                    Text("NITRO")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(InkColor.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(Palette.skeletonPlate)
                        )
                }
            }
            switch section {
            case .nameplate: nameplateTile
            case .avatar: avatarRow
            case .banner: bannerTile
            case .colours: coloursTile
            case .effectAndFrame: effectAndFrameRow
            case .displayNameStyle: displayNameStyleTile
            case .typingIndicator: typingIndicatorTile
            }
        }
    }

    /// The colour section is the one whose *name* changes with the account:
    /// "Banner Colour" free, "Theme & Banner" on Nitro. The single colour was
    /// always free — Nitro adds the second one and the banner image.
    private func title(for section: RailSection) -> String {
        guard section == .colours else { return section.title }
        return capability.canEditCurrentTheme ? "Profile Theme" : "Banner Colour"
    }

    /// Whether the account may use this section at all.
    ///
    /// Quoted from `PATCH /users/@me/profile`: `theme_colors` and
    /// `profile_effect_id` carry "can only be changed for premium users";
    /// `accent_color` does not, so the colour row itself is never locked — only
    /// its second well is.
    private func permits(_ section: RailSection) -> Bool {
        // In a locked server profile the one note at the top says it; a chip
        // on every row would say it six times.
        guard !capability.cosmeticsLocked else { return true }
        switch section {
        case .banner: return capability.canEditCurrentBanner
        case .effectAndFrame: return capability.canEditCurrentEffect
        // Marked for an account without Nitro, never locked: Discord says at
        // Save whether this account may wear one (D23).
        case .typingIndicator: return capability.customizesProfile
        case .nameplate, .avatar, .colours, .displayNameStyle: return true
        }
    }

    private var contentWidth: CGFloat { Self.width - Self.gutter * 2 }
    /// Two tiles and the gap between them.
    private var pairSide: CGFloat { (contentWidth - Spacing.snug) / 2 }

    // MARK: The tiles
    //
    // Each tile raises its flyout and **carries the anchor itself**, so the
    // flyout hangs off the thing that was clicked and points at it.

    private var nameplateTile: some View {
        NameplateEditTile(
            profile: profile,
            plate: editor.nameplate,
            width: contentWidth,
            open: { present(.nameplate) },
            clear: { editor.nameplate = nil }
        )
        .profileFlyout(.nameplate, at: .rail)
    }

    private var avatarRow: some View {
        HStack(spacing: Spacing.snug) {
            EditTile(side: pairSide, action: { present(.avatar) }) {
                AvatarView(
                    url: profile.avatarURL,
                    monogram: profile.monogram,
                    side: pairSide * 0.62,
                    decorationURL: nil
                )
            }
            .accessibilityLabel(Text("Change avatar"))
            .profileFlyout(.avatar, at: .rail)

            DecorationEditTile(
                side: pairSide,
                decorationURL: profile.decorationURL,
                open: { present(.decoration) },
                clear: {
                    editor.avatarDecorationSKU = nil
                    editor.decorationAsset = nil
                }
            )
            .profileFlyout(.decoration, at: .rail)
        }
    }

    /// The banner picture — what is set, or the colour behind it.
    private var bannerTile: some View {
        EditTile(side: contentWidth, aspect: 2.6, action: { present(.banner) }) {
            ZStack {
                Rectangle().fill(Color(hex: editor.themeStop(0)))
                if let url = profile.bannerURL {
                    RemoteImage(url: url, side: contentWidth, bucket: .artwork) { Color.clear }
                        .aspectRatio(contentMode: .fill)
                }
            }
            .clipShape(.rect(cornerRadius: Radius.chip - 4, style: .continuous))
        }
        .overlay { PlusBadge(isVisible: profile.bannerURL == nil) }
        .accessibilityLabel(Text("Change banner"))
        .profileFlyout(.banner, at: .rail)
    }

    /// The profile's colours as one swatch — the banner colour, or the theme's
    /// two ends as the gradient the card is painted with. Opens Wingcord's own
    /// picker (`ProfileColourFlyout`), not the system's.
    private var coloursTile: some View {
        Button { present(.colours) } label: {
            HStack(spacing: Spacing.base) {
                if capability.canEditCurrentTheme {
                    swatchDot(editor.themeStop(0))
                    swatchDot(editor.themeStop(1))
                } else {
                    swatchDot(editor.accentColor ?? editor.fallbackColour)
                }
                Text(capability.canEditCurrentTheme
                    ? ColourText.name(editor.themeStop(0))
                    : ColourText.name(editor.accentColor ?? editor.fallbackColour))
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(InkColor.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "paintpalette.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(InkColor.secondary)
            }
            .padding(.horizontal, Spacing.snug)
            .frame(height: 44)
            .background {
                RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                    .fill(.linearGradient(
                        colors: capability.canEditCurrentTheme
                            ? [Color(hex: editor.themeStop(0)).opacity(0.55), Color(hex: editor.themeStop(1)).opacity(0.55)]
                            : [Color(hex: editor.accentColor ?? editor.fallbackColour).opacity(0.45), Palette.skeletonPlate],
                        startPoint: .leading,
                        endPoint: .trailing
                    ))
            }
            .contentShape(.rect(cornerRadius: Radius.chip, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(capability.canEditCurrentTheme ? "Change profile theme" : "Change banner colour"))
        .profileFlyout(.colours, at: .rail)
    }

    private func swatchDot(_ value: UInt32) -> some View {
        Circle()
            .fill(Color(hex: value))
            .overlay { Circle().strokeBorder(.white.opacity(0.85), lineWidth: 2) }
            .frame(width: 20, height: 20)
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
    }

    private var displayNameStyleTile: some View {
        Button { present(.displayNameStyle) } label: {
            ZStack {
                RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                    .fill(Palette.skeletonPlate)
                // The reader's own name in the style they are choosing, which is
                // the only thing this tile could usefully show.
                StyledDisplayName(
                    text: profile.displayName,
                    style: editor.displayNameStyle,
                    textStyle: .title3,
                    weight: .bold
                )
                .padding(.horizontal, Spacing.group)
            }
            .frame(height: 56)
            .overlay(alignment: .trailing) {
                PlusBadge(isVisible: editor.displayNameStyle == nil)
                    .padding(.trailing, Spacing.snug)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Change display name style"))
        .profileFlyout(.displayNameStyle, at: .rail)
    }

    /// The indicator itself, with the reader's own name — what others will see
    /// above their composer.
    private var typingIndicatorTile: some View {
        Button { present(.typingIndicator) } label: {
            ZStack {
                RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                    .fill(Palette.skeletonPlate)
                TypingIndicator(
                    names: [profile.displayName],
                    style: editor.typingIndicatorStyle
                )
                .padding(.top, Spacing.tight)
            }
            .frame(height: 56)
            // At the end, not the middle: centred, it sat on the preview's
            // own words.
            .overlay(alignment: .trailing) {
                PlusBadge(isVisible: editor.typingIndicatorStyle == nil)
                    .padding(.trailing, Spacing.snug)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Change typing indicator"))
        .profileFlyout(.typingIndicator, at: .rail)
    }

    /// Effect and frame side by side — Discord's "Profile Effect & Frame".
    /// Both are written together as the profile's collectibles.
    private var effectAndFrameRow: some View {
        HStack(spacing: Spacing.snug) {
            VStack(spacing: Spacing.tight) {
                EditTile(side: pairSide, aspect: 0.78, action: { present(.effect) }) {
                    if let still = profile.effect?.reducedMotionURL {
                        RemoteImage(url: still, side: pairSide, bucket: .artwork) { MiniProfileSkeleton() }
                            .aspectRatio(contentMode: .fit)
                    } else {
                        MiniProfileSkeleton()
                    }
                }
                .overlay { PlusBadge(isVisible: editor.profileEffectSKU == nil) }
                .accessibilityLabel(Text("Change profile effect"))
                .profileFlyout(.effect, at: .rail)
                tileCaption("Effect")
            }
            VStack(spacing: Spacing.tight) {
                EditTile(side: pairSide, aspect: 0.78, action: { present(.frame) }) {
                    // The frame as worn, around the tile's own small card.
                    FrameThumbnail(frame: profile.frame, cardWidth: pairSide * 0.5)
                }
                .overlay { PlusBadge(isVisible: editor.profileFrameSKU == nil) }
                .accessibilityLabel(Text("Change profile frame"))
                .profileFlyout(.frame, at: .rail)
                tileCaption("Frame")
            }
        }
    }

    private func tileCaption(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption, weight: .medium))
            .foregroundStyle(InkColor.secondary)
    }

    // MARK: The upsell

    /// **Drawn only where something above it is actually locked.** A permanent
    /// advertisement at the foot of a panel is chrome the reader learns to stop
    /// seeing, and this app does not sell anything — the row exists because half
    /// the rail is inert without a subscription and saying so is more honest
    /// than letting four sheets each answer 403.
    @ViewBuilder
    private var nitroFooter: some View {
        // Whatever this scope's perk is, not "pays for nothing": Basic and
        // Classic are paid and still have half this rail locked.
        // A locked server profile says so once, at the top of the rail.
        if editor.scope.guildID == nil, !capability.customizesProfile {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Text("Some of these need Nitro.")
                    .font(Typeface.rowSubtitle)
                    .foregroundStyle(InkColor.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Self.gutter)
            .overlay(alignment: .top) {
                Rectangle().fill(Palette.railHairline).frame(height: 1)
            }
        }
    }
}

// MARK: - Which rows exist

private enum RailSection: Hashable, Identifiable {
    case nameplate
    case avatar
    case banner
    case colours
    case effectAndFrame
    case displayNameStyle
    case typingIndicator

    var id: Self { self }

    var title: String {
        switch self {
        case .nameplate: "Nameplate"
        case .avatar: "Avatar & Decoration"
        case .banner: "Banner"
        case .colours: "Banner Colour"
        case .effectAndFrame: "Profile Effect & Frame"
        case .displayNameStyle: "Display Name Style"
        case .typingIndicator: "Typing Indicator"
        }
    }
}

/// Which flyout a rail tile — or a pencil on the card — raises.
enum ProfileEditPicker: Hashable, Identifiable {
    case avatar
    case banner
    case colours
    case nameplate
    case decoration
    case effect
    case frame
    case displayNameStyle
    case typingIndicator
    /// Not a cosmetic and not in the rail — raised from the profile's own
    /// Connections section, and still a sheet: it is a sign-in, not a choice.
    case connection

    var id: Self { self }

    /// Which slice of `collectibles-purchases` this flyout shows, for the four
    /// that are a grid of owned artwork.
    var collectible: CollectibleKind? {
        switch self {
        case .avatar, .banner, .colours, .displayNameStyle, .typingIndicator, .connection: nil
        case .nameplate: .nameplate
        case .decoration: .avatarDecoration
        case .effect: .profileEffect
        case .frame: .profileFrame
        }
    }
}

/// One entry of the rail's scope menu.
struct ProfileEditScope: Hashable, Identifiable {
    var scope: ProfileEditor.Scope
    var title: String
    var iconURL: URL?
    /// The server's initials, for one with no icon — the rail's own fallback.
    var monogram: String = ""
    /// What the reader is called in that server, drawn under its name. Nil
    /// where they carry no nickname there — the row is then one line.
    var subtitle: String?

    var id: ProfileEditor.Scope { scope }

    static let main = ProfileEditScope(scope: .account, title: "Main Profile")
}

// MARK: - The tile shell

/// A rail tile: a plate, its artwork, and a hover lift.
private struct EditTile<Content: View>: View {
    var side: CGFloat
    /// Height as a multiple of the width. Square by default; the effect and
    /// frame cards are taller because a profile is.
    var aspect: CGFloat = 1
    var action: () -> Void
    @ViewBuilder var content: () -> Content

    @Environment(\.motion) private var motion
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                    .fill(Palette.skeletonPlate)
                content()
                    .padding(Spacing.base)
            }
            .frame(width: side, height: side / aspect)
            .contentShape(.rect(cornerRadius: Radius.chip, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .overlay {
            RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                .strokeBorder(Palette.railHairline, lineWidth: isHovering ? 1 : 0)
        }
        .animation(motion.hover, value: isHovering)
    }
}

/// The white `+` a tile wears where nothing is set.
private struct PlusBadge: View {
    var isVisible: Bool

    var body: some View {
        if isVisible {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Palette.canvas)
                .frame(width: 26, height: 26)
                .background(Circle().fill(.white))
                .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// The decoration tile: the ring the reader is wearing, or the dotted stand-in
/// where there is none.
///
/// **It draws the decoration around the Discord mark, not around the avatar** —
/// which is Discord's own arrangement and the right one: the tile is about the
/// ring, and putting somebody's face inside it makes the face the subject.
/// Hovering swaps in a trash, the same gesture the nameplate tile uses.
private struct DecorationEditTile: View {
    var side: CGFloat
    var decorationURL: URL?
    var open: () -> Void
    var clear: () -> Void

    @Environment(\.motion) private var motion
    @State private var isHovering = false

    var body: some View {
        EditTile(side: side, action: open) {
            if let decorationURL {
                RemoteImage(url: decorationURL, side: side, bucket: .thumbnail) {
                    DecorationSkeleton(side: side * 0.62)
                }
                .aspectRatio(contentMode: .fit)
            } else {
                DecorationSkeleton(side: side * 0.62)
            }
        }
        .overlay { PlusBadge(isVisible: decorationURL == nil) }
        .overlay(alignment: .topTrailing) {
            if decorationURL != nil, isHovering {
                Button(action: clear) {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(InkColor.primary)
                        .frame(width: 26, height: 26)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .interactiveChromeOverMedia(in: .rect(cornerRadius: 8, style: .continuous))
                .padding(Spacing.tight)
                .transition(.opacity)
                .accessibilityLabel(Text("Remove avatar decoration"))
            }
        }
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.fade, value: isHovering)
        .accessibilityLabel(Text("Change avatar decoration"))
    }
}

/// The dotted ring an unset avatar decoration stands in.
private struct DecorationSkeleton: View {
    var side: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Palette.skeletonInk, style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            Circle()
                .fill(Palette.skeletonInk)
                .padding(side * 0.14)
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}

// MARK: - The nameplate tile

/// The nameplate, which is the one tile that shows the reader themselves.
///
/// **Two stacked layers cross-fading, which is Discord's own arrangement.**
/// Their `avatarContainer__62b8c` is absolutely positioned at `opacity: 0` over
/// the placeholder and becomes `opacity: 1` on hover — the skeleton does not
/// leave, it is faded through. Both layers are always present, so the row never
/// changes height and nothing reflows under the pointer.
///
/// The cross-fade is the app's own 0.14s rather than Discord's 0.4s: the house
/// has one cross-fade and a rail that used a different one would be a rail with
/// its own opinion about the app's motion.
private struct NameplateEditTile: View {
    var profile: ProfilePresentation
    /// The plate as the **draft** wears it, which is not always the one on the
    /// profile: picking a new one has to show immediately, before any save.
    var plate: Nameplate?
    var width: CGFloat
    var open: () -> Void
    var clear: () -> Void

    @Environment(\.motion) private var motion
    @State private var isHovering = false

    /// `nameplatePreview__62b8c` at default density.
    private static let height: CGFloat = 42
    /// `overlayContainer__62b8c`'s `margin-inline: 8px 32px`.
    private static let leadingInset: CGFloat = 8
    private static let trailingInset: CGFloat = 32
    /// `avatar__62b8c`'s `margin-inline-end`.
    private static let avatarGap: CGFloat = 12
    /// `placeholderUsername__62b8c`: 14 tall at 66% of the container.
    private static let barHeight: CGFloat = 14
    private static let barFraction: CGFloat = 0.66

    private var containerWidth: CGFloat {
        width - Self.leadingInset - Self.trailingInset
    }

    var body: some View {
        Button(action: open) {
            ZStack(alignment: .leading) {
                artwork
                placeholder.opacity(isHovering ? 0 : 1)
                identity.opacity(isHovering ? 1 : 0)
            }
            .frame(width: width, height: Self.height)
            .clipShape(.rect(cornerRadius: Radius.chip, style: .continuous))
            .contentShape(.rect(cornerRadius: Radius.chip, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .overlay(alignment: .trailing) { trashButton }
        .animation(motion.fade, value: isHovering)
        .accessibilityLabel(Text("Change nameplate"))
    }

    /// The plate itself, and a skeleton where nothing is worn — so the row keeps
    /// its shape either way and the cross-fade above has something to sit on.
    @ViewBuilder
    private var artwork: some View {
        if let plate {
            // **Clipped to its own box before the stack composes it.** An
            // aspect-filled image reports the *image's* width upward, so the
            // `ZStack` grew past the tile and the outer frame then centred it —
            // which cut the avatar in half at the leading edge. Sizing and
            // clipping here means what the stack sees is already the tile.
            NameplateArtwork(
                still: plate.artworkURL,
                animated: plate.animatedArtworkURL,
                width: width,
                contentMode: .fill,
                // The same hover this tile already cross-fades on: the moment
                // the reader looks at the plate is the moment the identity
                // layer comes up over it.
                isAnimating: isHovering
            ) {
                Rectangle().fill(Palette.skeletonPlate)
            }
            .frame(width: width, height: Self.height)
            .clipped()
        } else {
            Rectangle().fill(Palette.skeletonPlate)
        }
    }

    private var placeholder: some View {
        HStack(spacing: Self.avatarGap) {
            Circle()
                .fill(Palette.skeletonInk)
                .frame(width: Self.height * 0.62, height: Self.height * 0.62)
            SkeletonBar(
                width: containerWidth * Self.barFraction,
                height: Self.barHeight
            )
        }
        .padding(.leading, Self.leadingInset)
        .accessibilityHidden(true)
    }

    private var identity: some View {
        HStack(spacing: Self.avatarGap) {
            AvatarView(
                url: profile.avatarURL,
                monogram: profile.monogram,
                side: Self.height * 0.62,
                decorationURL: nil
            )
            Text(profile.displayName)
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(InkColor.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, Self.leadingInset)
        .padding(.trailing, Self.trailingInset)
    }

    /// **Only where something is worn, and only under the pointer.** A remove
    /// control over an empty plate removes nothing, and one that is always drawn
    /// is a destructive target sitting permanently under the reader's hand.
    @ViewBuilder
    private var trashButton: some View {
        if plate != nil, isHovering {
            Button(action: clear) {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(InkColor.primary)
                    .frame(width: 26, height: 26)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .interactiveChromeOverMedia(in: .rect(cornerRadius: 8, style: .continuous))
            .padding(.trailing, Spacing.tight)
            .transition(.opacity)
            .accessibilityLabel(Text("Remove nameplate"))
        }
    }
}
