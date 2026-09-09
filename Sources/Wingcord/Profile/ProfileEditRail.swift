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
    var present: (ProfileEditPicker) -> Void

    @Environment(\.motion) private var motion

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
                    ForEach(sections) { section in
                        railSection(section)
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
        // **No menu for one scope.** A picker with a single entry is a label
        // that looks pressable — the same rule the profile's own tab strip
        // follows.
        if scopes.count > 1 {
            Menu {
                ForEach(scopes) { scope in
                    Button {
                        selectScope(scope)
                    } label: {
                        Label {
                            Text(scope.title)
                        } icon: {
                            if scope.id == currentScope.id { Image(systemName: "checkmark") }
                        }
                    }
                }
            } label: {
                HStack(spacing: Spacing.tight) {
                    Text(currentScope.title)
                        .font(.system(.body, weight: .semibold))
                        .foregroundStyle(InkColor.primary)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(InkColor.tertiary)
                }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()
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
    /// A server profile has no banner colour of its own on a free account and no
    /// profile frame at all, so those rows are absent rather than drawn disabled
    /// — a control that can never do anything is not a control.
    /// **A row is here only when the whole path behind it works** — a picker to
    /// choose in and a captured route to save with. Two are deliberately
    /// missing:
    ///
    ///  - **The profile frame.** No capture and no documentation names the field
    ///    that sets one; `PATCH /users/@me/profile` takes
    ///    `profile_effect_sku_id` and there is no frame twin. A tile that opened
    ///    a grid whose Apply could not be written is `INVARIANTS.md` §5.5.
    ///  - **The display name style.** The write is captured — three flat keys on
    ///    `PATCH /users/@me` — and the chooser is not built.
    private var sections: [RailSection] {
        switch editor.scope {
        case .account: [.nameplate, .avatar, .bannerColour, .effect, .displayNameStyle]
        case .guild: [.nameplate, .avatar, .displayNameStyle]
        }
    }

    @ViewBuilder
    private func railSection(_ section: RailSection) -> some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            Text(section.title)
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(InkColor.primary)
            switch section {
            case .nameplate: nameplateTile
            case .avatar: avatarRow
            case .bannerColour: bannerColourTile
            case .effect: effectTile
            case .displayNameStyle: displayNameStyleTile
            }
        }
    }

    private var contentWidth: CGFloat { Self.width - Self.gutter * 2 }
    /// Two tiles and the gap between them.
    private var pairSide: CGFloat { (contentWidth - Spacing.snug) / 2 }

    // MARK: The tiles

    private var nameplateTile: some View {
        NameplateEditTile(
            profile: profile,
            plate: editor.nameplate,
            width: contentWidth,
            open: { present(.nameplate) },
            clear: { editor.nameplate = nil }
        )
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

            DecorationEditTile(
                side: pairSide,
                decorationURL: profile.decorationURL,
                open: { present(.decoration) },
                clear: {
                    editor.avatarDecorationSKU = nil
                    editor.decorationAsset = nil
                }
            )
        }
    }

    /// **The system's own colour picker, not a sheet of swatches.** A colour is
    /// the one thing here that is not a grid of artwork somebody bought — macOS
    /// already has the eyedropper, the palettes and the accessibility support,
    /// and a hand-rolled grid would be a worse version of all three.
    private var bannerColourTile: some View {
        ColorPicker(
            "Banner Colour",
            selection: Binding(
                get: { editor.accentColor.map { Color(hex: $0) } ?? Palette.skeletonPlate },
                set: { editor.accentColor = $0.rgbValue }
            ),
            supportsOpacity: false
        )
        .labelsHidden()
        .frame(maxWidth: .infinity, alignment: .leading)
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
            .overlay { PlusBadge(isVisible: editor.displayNameStyle == nil) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Change display name style"))
    }

    private var effectTile: some View {
        HStack(spacing: Spacing.snug) {
            EditTile(side: pairSide, aspect: 0.78, action: { present(.effect) }) {
                MiniProfileSkeleton()
            }
            .overlay { PlusBadge(isVisible: editor.profileEffectSKU == nil) }
            .accessibilityLabel(Text("Change profile effect"))
            Spacer(minLength: 0)
        }
    }

    // MARK: The upsell

    /// **Drawn only where something above it is actually locked.** A permanent
    /// advertisement at the foot of a panel is chrome the reader learns to stop
    /// seeing, and this app does not sell anything — the row exists because half
    /// the rail is inert without a subscription and saying so is more honest
    /// than letting four sheets each answer 403.
    @ViewBuilder
    private var nitroFooter: some View {
        if profile.premiumTier == .none {
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
    case bannerColour
    case effect
    case displayNameStyle

    var id: Self { self }

    var title: String {
        switch self {
        case .nameplate: "Nameplate"
        case .avatar: "Avatar & Decoration"
        case .bannerColour: "Banner Colour"
        case .effect: "Profile Effect"
        case .displayNameStyle: "Display Name Style"
        }
    }
}

/// Which sheet a rail tile raises.
enum ProfileEditPicker: Hashable, Identifiable {
    case avatar
    case nameplate
    case decoration
    case effect
    case displayNameStyle
    /// Not a cosmetic and not in the rail — raised from the profile's own
    /// Connections section, which is the only place it makes sense from.
    case connection

    var id: Self { self }

    /// Which slice of `collectibles-purchases` this picker shows, for the three
    /// that are a grid of owned artwork. **The avatar is not one of them** — it
    /// is a file, a recents list and a removal, and none of those is a purchase.
    var collectible: CollectibleKind? {
        switch self {
        case .avatar, .displayNameStyle, .connection: nil
        case .nameplate: .nameplate
        case .decoration: .avatarDecoration
        case .effect: .profileEffect
        }
    }
}

/// One entry of the rail's scope menu.
struct ProfileEditScope: Hashable, Identifiable {
    var scope: ProfileEditor.Scope
    var title: String
    var iconURL: URL?

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
