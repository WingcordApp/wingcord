import SwiftUI
import WingcordCore

/// Choosing a nameplate, a profile effect, a profile frame or an avatar
/// decoration — as a flyout off the tile that raised it.
///
/// **One flyout for four cosmetics, because there is one route behind them.**
/// `GET /users/@me/collectibles-purchases` answers every purchase the reader
/// owns in a single array tagged by kind, so the four grids are that answer
/// filtered — `AppModel.ownedCollectibles(of:)`, which asks once per session.
///
/// **A tile is the choice, not a step towards one.** It lands in the draft at
/// once, the profile beside the flyout wears it, and the save bar commits it
/// with everything else (screenshot 14 was a sheet with Cancel and Apply over
/// the very profile it changed).
///
/// **What is not here is the shop.** Discord's grids carry a "See What's in
/// Shop" section drawn from `collectibles-categories/v2`, a route this client
/// has no capture of — and this client sells nothing.
struct CollectibleFlyout: View {
    var kind: CollectibleKind
    var editor: ProfileEditor

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var owned: [OwnedCollectible] = []
    @State private var isLoading = true
    @State private var failure: String?

    private var columns: Int {
        switch kind {
        case .nameplate: 1
        case .avatarDecoration: 4
        case .profileEffect, .profileFrame: 3
        }
    }

    /// `premium_type == 2` exactly — Basic is paid and carries none of these.
    private var wearsNitro: Bool { model.entitlements.premiumTier == .nitro }

    private var chosen: OwnedCollectible? {
        owned.first { $0.skuID == editor.worn(kind) }
    }

    var body: some View {
        FlyoutScaffold(title: kind.pickerTitle, subtitle: subtitle, width: kind == .nameplate ? 340 : 330) {
            if kind == .nameplate {
                NameplateFlyoutPreview(profile: editor.applied(to: editor.base), plate: editor.nameplate)
            }
            content
        }
        .task { await load() }
    }

    /// "Cosmic Storm · Acquired October 2025", or what the grid is.
    private var subtitle: String {
        guard let chosen else { return editor.worn(kind) == nil ? "None" : kind.ownedHeading }
        guard let acquired = chosen.acquiredAt else { return chosen.name }
        return "\(chosen.name) · Acquired \(acquired.formatted(.dateTime.month(.wide).year()))"
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, minHeight: 120)
        } else if let failure {
            Text(failure)
                .font(.system(.subheadline))
                .foregroundStyle(InkColor.secondary)
                .frame(maxWidth: .infinity, minHeight: 120)
                .multilineTextAlignment(.center)
        } else {
            ScrollView {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.base), count: columns),
                    spacing: Spacing.base
                ) {
                    noneTile
                    ForEach(owned) { tile($0) }
                }
                .padding(2)
                if owned.isEmpty {
                    Text(kind.emptyLine)
                        .font(.system(.subheadline))
                        .foregroundStyle(InkColor.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, Spacing.base)
                }
            }
            .scrollIndicators(.never)
            .frame(maxHeight: 360)
            .fixedSize(horizontal: false, vertical: true)
            .animation(motion.hover, value: editor.worn(kind))
        }
    }

    private var noneTile: some View {
        FlyoutTile(isSelected: editor.worn(kind) == nil, height: tileHeight) {
            choose(nil)
        } content: {
            VStack(spacing: Spacing.tight) {
                Image(systemName: "circle.slash")
                    .font(.system(size: 18))
                    .foregroundStyle(InkColor.secondary)
                Text("None")
                    .font(.system(.caption, weight: .medium))
                    .foregroundStyle(InkColor.secondary)
            }
        }
        .accessibilityLabel(Text("None"))
    }

    private var tileHeight: CGFloat {
        switch kind {
        case .nameplate: 42
        case .avatarDecoration: 64
        case .profileEffect, .profileFrame: 92
        }
    }

    private func tile(_ item: OwnedCollectible) -> some View {
        let wearable = !item.isNitroExclusive || wearsNitro
        return FlyoutTile(isSelected: editor.worn(kind) == item.skuID, height: tileHeight, insets: kind == .nameplate ? 0 : Spacing.tight) {
            guard wearable else { return }
            choose(item)
        } content: {
            artwork(item)
        }
        .opacity(wearable ? 1 : 0.4)
        .overlay(alignment: .topTrailing) {
            if !wearable {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(Circle().fill(.black.opacity(0.55)))
                    .padding(4)
            }
        }
        .help(wearable ? item.name : "\(item.name) — only Nitro subscribers can wear this.")
        .accessibilityLabel(Text(wearable ? (item.label ?? item.name) : "\(item.label ?? item.name), Nitro only"))
    }

    @ViewBuilder
    private func artwork(_ item: OwnedCollectible) -> some View {
        switch item.kind {
        case .nameplate:
            FlyoutNameplate(item: item)
        case .avatarDecoration:
            RemoteImage(url: CDN.avatarDecoration(hash: item.asset), side: 52, bucket: .artwork) {
                Color.clear
            }
            .aspectRatio(contentMode: .fit)
            .frame(width: 52, height: 52)
        case .profileEffect:
            VStack(spacing: 3) {
                if let still = model.profileEffects[item.skuID]?.reducedMotionURL {
                    RemoteImage(url: still, side: 70, bucket: .artwork) { MiniProfileSkeleton() }
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 64)
                } else {
                    MiniProfileSkeleton().frame(width: 44, height: 58)
                }
                tileName(item.name)
            }
        case .profileFrame:
            VStack(spacing: 3) {
                FrameThumbnail(frame: model.profileFrames[item.skuID])
                    .frame(height: 70)
                tileName(item.name)
            }
        }
    }

    private func tileName(_ name: String) -> some View {
        Text(name)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(InkColor.secondary)
            .lineLimit(1)
    }

    private func choose(_ item: OwnedCollectible?) {
        editor.wear(item, kind: kind)
        Haptics.pop()
        // The card beside the flyout draws a chosen effect or frame from its
        // product, which the profile route never sent for this one.
        if let item, kind == .profileEffect || kind == .profileFrame {
            model.resolveCollectible(sku: item.skuID)
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            owned = try await model.ownedCollectibles(of: kind)
            // Thumbnails for effects and frames live on their products.
            if kind == .profileEffect || kind == .profileFrame {
                for item in owned { model.resolveCollectible(sku: item.skuID) }
            }
        } catch {
            failure = "Couldn't load what you own. \(error.localizedDescription)"
        }
    }
}

/// The reader's own member row wearing the plate — where a nameplate is seen.
private struct NameplateFlyoutPreview: View {
    var profile: ProfilePresentation
    var plate: Nameplate?

    var body: some View {
        HStack(spacing: Spacing.snug) {
            AvatarView(url: profile.avatarURL, monogram: profile.monogram, side: 28, decorationURL: nil)
            Text(profile.displayName)
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(InkColor.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.base)
        .frame(height: 46)
        .background {
            ZStack {
                Palette.canvas
                if let plate {
                    NameplateArtwork(
                        still: plate.artworkURL,
                        animated: plate.animatedArtworkURL,
                        width: 308,
                        contentMode: .fill,
                        isAnimating: true
                    )
                }
            }
        }
        .clipShape(.rect(cornerRadius: Radius.row, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Preview: \(profile.displayName)\(plate.map { ", wearing \($0.label ?? "a nameplate")" } ?? "")"))
    }
}

/// One nameplate in the grid — moving only under the pointer, so a grid of
/// them settles.
private struct FlyoutNameplate: View {
    var item: OwnedCollectible

    @State private var isHovering = false

    var body: some View {
        ZStack(alignment: .leading) {
            NameplateArtwork(
                still: CDN.nameplate(asset: item.asset),
                animated: CDN.animatedNameplate(asset: item.asset),
                width: 308,
                contentMode: .fill,
                isAnimating: isHovering
            ) {
                Rectangle().fill(Palette.skeletonPlate)
            }
            Text(item.name)
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.55), radius: 3)
                .padding(.leading, Spacing.snug)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 42)
        .clipShape(.rect(cornerRadius: Radius.chip, style: .continuous))
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
    }
}

/// A selectable tile in a flyout's grid, with the accent ring for the one worn.
struct FlyoutTile<Content: View>: View {
    var isSelected: Bool
    var height: CGFloat
    var insets: CGFloat = Spacing.tight
    var select: () -> Void
    @ViewBuilder var content: () -> Content

    @Environment(\.motion) private var motion
    @State private var isHovering = false

    var body: some View {
        Button(action: select) {
            content()
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .padding(insets)
                .background {
                    RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                        .fill(isHovering ? Palette.hoverFill : Palette.skeletonPlate)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                        .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
                }
                .contentShape(.rect(cornerRadius: Radius.chip, style: .continuous))
                .scaleEffect(isSelected ? 1 : (isHovering ? 1.02 : 1))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.hover, value: isHovering)
        .animation(motion.hover, value: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

extension CollectibleKind {
    var pickerTitle: String {
        switch self {
        case .nameplate: "Change Nameplate"
        case .profileEffect: "Change Profile Effect"
        case .profileFrame: "Change Profile Frame"
        case .avatarDecoration: "Change Avatar Decoration"
        }
    }

    var ownedHeading: String {
        switch self {
        case .nameplate: "Your Nameplates"
        case .profileEffect: "Your Effects"
        case .profileFrame: "Your Frames"
        case .avatarDecoration: "Your Decorations"
        }
    }

    /// What an empty grid says. Not "nothing here" — the honest answer is that
    /// these are bought, and this client cannot sell them.
    var emptyLine: String {
        switch self {
        case .nameplate: "You don't own any nameplates yet."
        case .profileEffect: "You don't own any profile effects yet."
        case .profileFrame: "You don't own any profile frames yet."
        case .avatarDecoration: "You don't own any avatar decorations yet."
        }
    }
}

/// A frame as it is worn — the whole composition around a small card, every
/// piece where its own payload puts it. A single piece cut out of it (the
/// first thumbnail) put a top-left corner of roses in the middle of the tile.
struct FrameThumbnail: View {
    var frame: ProfileFrame?
    var cardWidth: CGFloat = 40

    var body: some View {
        let card = MiniProfileSkeleton(isDashed: frame == nil)
            .frame(width: cardWidth, height: cardWidth * 1.3)
        if let frame {
            card
                .profileFrame(frame, cardWidth: cardWidth, fadesIn: false)
                .fixedSize()
        } else {
            card
        }
    }
}
