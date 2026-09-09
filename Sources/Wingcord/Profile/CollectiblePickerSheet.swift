import SwiftUI
import WingcordCore
import WingcordNet

/// Choosing a nameplate, a profile effect, a profile frame or an avatar
/// decoration.
///
/// **One sheet for four cosmetics, because there is one route behind them.**
/// `GET /users/@me/collectibles-purchases` answers every purchase the reader
/// owns in a single array tagged by kind — there is no per-kind route — so four
/// sheets would be four identical requests and four copies of the same grid.
/// Discord's own four dialogs differ only in their title and which kind they
/// filter to, and so do these.
///
/// **What is *not* here is the shop.** Discord's grids carry a "See What's in
/// Shop" section under the owned one, drawn from `collectibles-categories/v2` —
/// a route this client has never called and has no capture of. A locked grid of
/// artwork nobody can buy from inside this app is decoration; when the route is
/// captured it goes below the owned section, where Discord puts it.
struct CollectiblePickerSheet: View {
    var kind: CollectibleKind
    var profile: ProfilePresentation
    /// The sku currently worn, or nil for none.
    var selection: String?
    /// **The whole collectible, not its sku.** A sku cannot be drawn — the
    /// rail's tile has to show the artwork the moment it is chosen, and the
    /// asset that addresses it lives only on the item.
    var apply: (OwnedCollectible?) -> Void
    var dismiss: () -> Void

    @Environment(AppModel.self) private var model
    @State private var owned: [OwnedCollectible] = []
    @State private var isLoading = true
    @State private var failure: String?
    @State private var draft: String?

    private static let tile: CGFloat = 96
    /// **A nameplate is a strip, not a square.** At three to a row its artwork
    /// has 100 points to live in and is cropped to a smear; one per row gives it
    /// the shape it was authored at. The square cosmetics still tile three
    /// across.
    private var columns: Int { kind == .nameplate ? 1 : 3 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Palette.railHairline)
            HStack(alignment: .top, spacing: 0) {
                content
                Divider().overlay(Palette.railHairline)
                preview
            }
            Divider().overlay(Palette.railHairline)
            footer
        }
        .frame(width: 780, height: 520)
        .background(Palette.surface)
        .clipShape(.rect(cornerRadius: Radius.card, style: .continuous))
        .task {
            draft = selection
            await load()
        }
    }

    // MARK: Chrome

    private var header: some View {
        HStack {
            Text(kind.pickerTitle)
                .font(.system(.title3, weight: .bold))
                .foregroundStyle(InkColor.primary)
            Spacer(minLength: Spacing.margin)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(.caption, weight: .bold))
                    .foregroundStyle(InkColor.secondary)
                    .frame(width: Metrics.control, height: Metrics.control)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Close"))
        }
        .padding(.horizontal, Spacing.group)
        .padding(.vertical, Spacing.margin)
    }

    private var footer: some View {
        HStack(spacing: Spacing.snug) {
            Spacer(minLength: 0)
            Button("Cancel", action: dismiss)
                .buttonStyle(.plain)
                .font(.system(.subheadline, weight: .medium))
                .foregroundStyle(InkColor.primary)
                .padding(.horizontal, Spacing.margin)
                .frame(height: Metrics.control)
                .interactiveChromeOverMedia(in: .rect(cornerRadius: 8, style: .continuous))

            Button("Apply") { apply(owned.first { $0.skuID == draft }) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                // **Nothing to apply is not a button to press.** Re-sending the
                // sku already worn is a request that changes nothing and a save
                // bar that comes up for it.
                .disabled(draft == selection)
        }
        .padding(.horizontal, Spacing.group)
        .padding(.vertical, Spacing.snug)
    }

    // MARK: The preview

    /// What the choice will look like, on the surface it is actually worn on.
    ///
    /// **Two shapes, because a cosmetic is worn in two different places.** A
    /// nameplate is a strip behind a roster row, so its preview is a member list
    /// with the reader's own row in it; an effect and a frame dress the profile
    /// card, so they share one — which is Discord's own arrangement, and the
    /// reason those two sheets look identical apart from their title.
    private var preview: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            switch kind {
            case .nameplate: NameplatePreviewBox(profile: profile, plate: draftPlate)
            case .profileEffect, .profileFrame: SampleProfileCard(profile: profile)
            case .avatarDecoration:
                // The staged choice, so the ring changes as tiles are clicked
                // rather than only after Apply.
                AvatarDecorationPreview(
                    profile: profile,
                    decorationURL: draftDecorationURL
                )
            }
            if let chosen = owned.first(where: { $0.skuID == draft }) {
                acquiredCard(chosen)
            }
            Spacer(minLength: 0)
        }
        .padding(Spacing.group)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The ring the grid currently has staged. Nil is "None", which is a real
    /// choice here and not an absence — so the preview shows a bare avatar.
    private var draftDecorationURL: URL? {
        guard let item = owned.first(where: { $0.skuID == draft }) else { return nil }
        return CDN.avatarDecoration(hash: item.asset)
    }

    /// The plate as the sheet currently has it staged, so the preview follows
    /// the grid rather than what is saved.
    private var draftPlate: Nameplate? {
        guard let item = owned.first(where: { $0.skuID == draft }) else { return nil }
        return Nameplate(
            asset: item.asset,
            palette: item.palette.flatMap(NameplatePalette.init(rawValue:)) ?? .none,
            label: item.label,
            skuID: item.skuID
        )
    }

    /// "Cosmic Storm / Acquired October 2025" — the one place `purchased_at` is
    /// read, and the reason the decoder keeps it.
    private func acquiredCard(_ item: OwnedCollectible) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.name)
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(InkColor.primary)
            if let acquired = item.acquiredAt {
                Text("Acquired \(acquired.formatted(.dateTime.month(.wide).year()))")
                    .font(Typeface.rowSubtitle)
                    .foregroundStyle(InkColor.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.snug)
        .background {
            RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                .strokeBorder(Palette.railHairline, lineWidth: 1)
        }
    }

    // MARK: The grid

    @ViewBuilder
    private var content: some View {
        if isLoading {
            centred { ProgressView().controlSize(.small) }
                .frame(width: 360)
        } else if let failure {
            centred {
                Text(failure)
                    .font(Typeface.rowSubtitle)
                    .foregroundStyle(InkColor.secondary)
                    .multilineTextAlignment(.center)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.snug) {
                    Text(kind.ownedHeading)
                        .font(Typeface.sectionHeader)
                        .foregroundStyle(InkColor.tertiary)
                        .textCase(.uppercase)
                        .tracking(0.9)

                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(.flexible(), spacing: Spacing.snug),
                            count: columns
                        ),
                        spacing: Spacing.snug
                    ) {
                        noneTile
                        ForEach(owned) { item in
                            tile(for: item)
                        }
                    }

                    if owned.isEmpty {
                        Text(kind.emptyLine)
                            .font(Typeface.rowSubtitle)
                            .foregroundStyle(InkColor.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, Spacing.tight)
                    }
                }
                .padding(Spacing.group)
            }
            .scrollIndicators(.never)
            .frame(width: 360)
        }
    }

    private func centred(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .frame(maxWidth: .infinity, minHeight: 200)
            .padding(Spacing.group)
    }

    private var noneTile: some View {
        PickerTile(isSelected: draft == nil) { draft = nil } content: {
            VStack(spacing: Spacing.tight) {
                Image(systemName: "circle.slash")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(InkColor.secondary)
                Text("None")
                    .font(Typeface.rowSubtitle)
                    .foregroundStyle(InkColor.secondary)
            }
        }
        .accessibilityLabel(Text("None"))
    }

    private func tile(for item: OwnedCollectible) -> some View {
        PickerTile(isSelected: draft == item.skuID, isWide: kind == .nameplate) {
            draft = item.skuID
        } content: {
            // A strip carries its name beside the artwork; a square carries it
            // underneath, because there is no room beside it.
            if kind == .nameplate {
                artwork(for: item)
            } else {
                VStack(spacing: Spacing.tight) {
                    artwork(for: item)
                    Text(item.name)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(InkColor.secondary)
                        .lineLimit(1)
                }
            }
        }
        // The label the artwork was authored with, which is the only description
        // a reader who cannot see it will get.
        .accessibilityLabel(Text(item.label ?? item.name))
    }

    /// **Two kinds have an addressable picture and two do not.** A nameplate is
    /// a CDN path and a decoration is a hash; an effect and a frame are
    /// compositions of several layers whose thumbnail lives in the shop
    /// catalogue, and this route carries no preview for them. Those draw their
    /// name rather than a broken box.
    @ViewBuilder
    private func artwork(for item: OwnedCollectible) -> some View {
        switch item.kind {
        case .nameplate:
            // The whole strip, with the name over it — which is what a nameplate
            // is. `.fill` inside a short box crops it to a smear of whatever
            // happens to be in the middle.
            ZStack(alignment: .leading) {
                RemoteImage(
                    url: CDN.nameplate(asset: item.asset),
                    side: 320,
                    bucket: .artwork
                ) {
                    Rectangle().fill(Palette.skeletonPlate)
                }
                .aspectRatio(contentMode: .fill)
                Text(item.name)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.55), radius: 3)
                    .padding(.leading, Spacing.snug)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .clipShape(.rect(cornerRadius: Radius.chip, style: .continuous))
        case .avatarDecoration:
            RemoteImage(
                url: CDN.avatarDecoration(hash: item.asset),
                side: 48,
                bucket: .artwork
            ) {
                Color.clear
            }
            .aspectRatio(contentMode: .fit)
            .frame(width: 48, height: 48)
        case .profileEffect, .profileFrame:
            MiniProfileSkeleton(isDashed: item.kind == .profileFrame)
                .frame(width: 40, height: 52)
        }
    }

    // MARK: Loading

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let all = try await model.sessionController.rest.ownedCollectibles()
            owned = all.filter { $0.kind == kind }
        } catch {
            failure = "Couldn't load what you own. \(error.localizedDescription)"
        }
    }
}

/// One selectable square in the grid.
private struct PickerTile<Content: View>: View {
    var isSelected: Bool
    /// A strip fills its row and sets its own height; a square is a fixed box.
    var isWide = false
    var select: () -> Void
    @ViewBuilder var content: () -> Content

    @Environment(\.motion) private var motion

    var body: some View {
        Button(action: select) {
            content()
                .frame(maxWidth: .infinity)
                .frame(height: isWide ? nil : 84)
                .padding(Spacing.base)
                .background {
                    RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                        .fill(Palette.skeletonPlate)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                        .strokeBorder(
                            isSelected ? Color.accentColor : .clear,
                            lineWidth: 2
                        )
                }
                .contentShape(.rect(cornerRadius: Radius.chip, style: .continuous))
        }
        .buttonStyle(.plain)
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
