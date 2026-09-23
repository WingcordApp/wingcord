import AppKit
import SwiftUI
import WingcordCore
import UniformTypeIdentifiers

// MARK: - Picking an image
//
// Three pages upload one: the server icon, the tag profile's banner, a webhook's
// avatar. One control, because three file pickers is three places to forget the
// size limit.

/// A preview, a Change button and a Remove button.
///
/// **The size limit is stated, not enforced.** Discord's route is the authority
/// and refuses an oversized file with a message worth showing; a client that
/// checked first would be a second opinion that goes stale the week the limit
/// changes. What the line under the well is for is telling somebody *before*
/// they choose.
struct ImageWell: View {
    var title: String
    var detail: String
    var url: URL?
    var isCircular: Bool
    var onPick: (ImageData) -> Void
    /// Nil where there is nothing to remove.
    var onRemove: (() -> Void)?

    @State private var failure: String?

    var body: some View {
        HStack(spacing: SettingsMetrics.navigationIconGap) {
            preview
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(SettingsType.rowTitle)
                    .foregroundStyle(Ink.primary)
                Text(failure ?? detail)
                    .font(SettingsType.rowSubtitle)
                    .foregroundStyle(failure == nil ? AnyShapeStyle(Ink.secondary) : AnyShapeStyle(Palette.destructive))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Spacing.base)
            HStack(spacing: Spacing.tight) {
                Button("Change", action: pick)
                    .buttonStyle(.glass)
                    .controlSize(.small)
                if let onRemove {
                    Button("Remove", role: .destructive, action: onRemove)
                        .buttonStyle(.plain)
                        .font(.system(.caption))
                        .foregroundStyle(Palette.destructive)
                }
            }
        }
        .padding(.leading, SettingsMetrics.navigationIconLeading)
        .padding(.trailing, SettingsMetrics.controlTrailing)
        .frame(maxWidth: .infinity, minHeight: SettingsMetrics.navigationRowHeight)
        .accessibilityElement(children: .contain)
    }

    private var preview: some View {
        Group {
            if let url {
                RemoteImage(url: url, side: 44) { placeholder }
            } else {
                placeholder
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(isCircular ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 8, style: .continuous)))
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        SettingsSurface.controlTrough
            .overlay {
                Image(systemName: "photo")
                    .font(.system(size: 15))
                    .foregroundStyle(Ink.tertiary)
            }
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .gif]
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        do {
            let bytes = try Data(contentsOf: chosen)
            // GIF goes up as GIF — an animated icon re-encoded to PNG is a
            // still, and the reader would have uploaded an animation and got a
            // frame. Everything else is normalised to PNG, which is what the
            // reference client does when it crops.
            let isGIF = chosen.pathExtension.lowercased() == "gif"
            failure = nil
            onPick(isGIF ? .gif(bytes) : ImageData(mimeType: mimeType(for: chosen), bytes: bytes))
        } catch {
            failure = "That file could not be read."
        }
    }

    private func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        default: "image/png"
        }
    }
}

// MARK: - The banner swatch

/// The colours the Server Profile page offers for `brand_color_primary`.
///
/// **One of these is captured and the rest are this client's own.** Choosing the
/// pink tile in the reference sent `"#ff1c90"`, which is the second entry below;
/// the other nine tiles' exact values were never in a request, and inventing
/// nine hex codes and presenting them as Discord's would be a fact stated
/// confidently and wrong.
///
/// So the grid is a spread of hues this client picked, and the colour well
/// beside it takes **any** value — which the route accepts, being a free hex
/// string. That is strictly more than the reference offers, and it is honest:
/// nothing here claims to be Discord's palette.
enum BrandColor {
    /// The captured one. Kept named so the comment above stays checkable.
    static let capturedPink: UInt32 = 0xFF1C90

    static let swatches: [UInt32] = [
        0x1F1F23, capturedPink, 0xE0344B, 0xF0883B,
        0xF5C518, 0xA855C7, 0x2DA8F0, 0x3CD6B4,
        0x5A9E36, 0x6E6E78,
    ]
}

struct BrandSwatch: View {
    var value: UInt32
    var isSelected: Bool
    var choose: () -> Void

    var body: some View {
        Button(action: choose) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(hex: value).opacity(0.55), Color(hex: value)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(height: 38)
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(
                            isSelected ? InkColor.solid : swatchRing,
                            lineWidth: isSelected ? 2 : 1
                        )
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Banner colour")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

// MARK: - Traits

enum GuildTraitLimits {
    /// Discord's own cap, stated on the page.
    static let maximum = 5
}

/// Up to five words, each with an optional emoji.
///
/// **Position is the array index and is written as such** — see
/// `updateGuildProfile`, which renumbers on every save. A list that echoed a
/// stored position would send 0, 2, 3 after a middle entry was deleted.
struct TraitEditor: View {
    @Binding var traits: [GuildTrait]
    var commit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            ForEach(Array(traits.enumerated()), id: \.offset) { index, trait in
                HStack(spacing: Spacing.base) {
                    Text(trait.glyph ?? "•")
                        .font(.system(size: 14))
                        .frame(width: 20)
                    TextField(
                        "Trait",
                        text: Binding(
                            get: { index < traits.count ? traits[index].label : "" },
                            set: { if index < traits.count { traits[index].label = $0 } }
                        )
                    )
                    .textFieldStyle(.plain)
                    .font(SettingsType.rowLabel)
                    .foregroundStyle(Ink.primary)
                    .onSubmit(commit)
                    RowIconButton(symbolName: "xmark", label: "Remove trait", role: .destructive) {
                        guard index < traits.count else { return }
                        traits.remove(at: index)
                        commit()
                    }
                }
                .padding(.horizontal, Spacing.base)
                .padding(.vertical, 6)
                .background(SettingsSurface.controlTrough, in: .settingsRect(7))
            }

            if traits.count < GuildTraitLimits.maximum {
                Button {
                    // Position is assigned at save, so a new trait takes the
                    // count as a placeholder and nothing depends on it.
                    traits.append(GuildTrait(id: traits.count, label: ""))
                } label: {
                    Label("Add a trait", systemImage: "plus")
                        .font(SettingsType.rowLabel)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.accent)
            }

            // A save button, because a trait list has no single field to blur
            // out of — deleting a row commits immediately, and typing into one
            // has to be finished deliberately.
            HStack {
                Spacer()
                Button("Save traits", action: commit)
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
        }
        .padding(SettingsMetrics.cardContentInset)
    }
}

// MARK: - Games

struct GameTile: View {
    var game: GameSummary
    var remove: () -> Void

    @State private var isHovered = false
    @Environment(\.motion) private var motion

    var body: some View {
        VStack(spacing: Spacing.tight) {
            RemoteImage(url: game.iconURL, side: 64) {
                SettingsSurface.controlTrough.overlay {
                    Image(systemName: "gamecontroller.fill")
                        .foregroundStyle(Ink.tertiary)
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(.rect(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if isHovered {
                    Button(action: remove) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(.white, Palette.destructive)
                    }
                    .buttonStyle(.plain)
                    .padding(3)
                    .accessibilityLabel("Remove \(game.name)")
                }
            }
            Text(game.name)
                .font(.system(.caption))
                .foregroundStyle(Ink.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .onHover { isHovered = $0 }
        .animation(motion.hover, value: isHovered)
    }
}

/// Search, and pick.
///
/// Debounced at 220 ms: the route answers per keystroke otherwise, and "valorant"
/// is eight requests for one answer. The task is keyed on the query so a new
/// keystroke cancels the pending one rather than racing it.
struct GamePickerSheet: View {
    let store: ServerSettingsStore
    var chosen: Set<ApplicationID>
    var pick: (GameSummary) -> Void

    @State private var query = ""
    @State private var results: [GameSummary] = []
    @State private var isSearching = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Add a game")
                    .font(.system(.headline))
                    .foregroundStyle(Ink.primary)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
            .padding(Spacing.margin)

            TextField("Search for a game…", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, Spacing.margin)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if isSearching {
                        LoadingRow()
                    } else if results.isEmpty, !query.isEmpty {
                        Text("No games matched.")
                            .font(SettingsType.rowLabel)
                            .foregroundStyle(Ink.secondary)
                            .padding(Spacing.margin)
                    }
                    ForEach(results) { game in
                        Button {
                            pick(game)
                            dismiss()
                        } label: {
                            ObjectRow(
                                title: game.name,
                                subtitle: chosen.contains(game.id) ? "Already added" : nil
                            ) {
                                RemoteImage(url: game.iconURL, side: 28) {
                                    SettingsSurface.controlTrough
                                }
                                .frame(width: 28, height: 28)
                                .clipShape(.rect(cornerRadius: 6, style: .continuous))
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(chosen.contains(game.id))
                    }
                }
            }
        }
        .frame(width: 420, height: 460)
        .background(Palette.surface)
        .task(id: query) {
            guard !query.isEmpty else {
                results = []
                return
            }
            isSearching = true
            // Cancelled by the next keystroke, which is what makes this a
            // debounce rather than a delay.
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            results = (try? await store.searchGames(query)) ?? []
            isSearching = false
        }
    }
}

// MARK: - The tag's badge

/// Thirty shapes in five packs.
///
/// Grouped, because thirty unlabelled glyphs in one grid is a wall — and locked
/// packs are shown with their requirement rather than hidden, since "why can I
/// not pick the cat" is a question the page should answer.
struct BadgePicker: View {
    @Binding var selection: GuildBadge?
    var features: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(GuildBadge.Pack.allCases) { pack in
                let badges = GuildBadge.allCases.filter { $0.pack == pack }
                let isUnlocked = pack.feature.map(features.contains) ?? true
                SettingsGroup(pack.title) {
                    SettingsCard {
                        LazyVGrid(
                            columns: Array(
                                repeating: GridItem(.flexible(), spacing: Spacing.base),
                                count: 5
                            ),
                            spacing: Spacing.base
                        ) {
                            ForEach(badges) { badge in
                                BadgeTile(
                                    badge: badge,
                                    isSelected: selection == badge,
                                    isEnabled: isUnlocked
                                ) {
                                    selection = badge
                                }
                            }
                        }
                        .padding(SettingsMetrics.cardContentInset)
                    }
                    if !isUnlocked {
                        SettingsFootnote(
                            "This pack is not unlocked for this server.",
                            symbolName: "lock.fill"
                        )
                    }
                }
            }
        }
    }
}

private struct BadgeTile: View {
    var badge: GuildBadge
    var isSelected: Bool
    var isEnabled: Bool
    var choose: () -> Void

    var body: some View {
        Button(action: choose) {
            VStack(spacing: 2) {
                Image(systemName: badge.symbolName)
                    .font(.system(size: 18))
                    .foregroundStyle(isEnabled ? Ink.primary : Ink.tertiary)
                    .frame(height: 24)
                Text(badge.title)
                    .font(.system(size: 9))
                    .foregroundStyle(Ink.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.base)
            .background(
                isSelected ? SettingsSurface.controlSelected : SettingsSurface.controlTrough,
                in: .settingsRect(8)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(badge.title)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

extension GuildBadge {
    /// The nearest SF Symbol.
    ///
    /// **An approximation, and deliberately so.** The real artwork is in
    /// Discord's own sprite sheets — four PNGs the docs link to — and this
    /// client does not ship them. A symbol that reads as "cat" where Discord
    /// draws a cat is a picker somebody can use; the alternative is thirty
    /// numbered squares.
    var symbolName: String {
        switch self {
        case .sword: "sword.fill"
        case .waterDrop: "drop.fill"
        case .skull: "theatermasks.fill"
        case .toadstool: "camera.macro"
        case .moon: "moon.fill"
        case .lightning: "bolt.fill"
        case .leaf: "leaf.fill"
        case .heart: "heart.fill"
        case .fire: "flame.fill"
        case .compass: "safari.fill"
        case .bunny: "hare.fill"
        case .dog: "dog.fill"
        case .frog: "ladybug.fill"
        case .goat: "pawprint.fill"
        case .cat: "cat.fill"
        case .diamond: "diamond.fill"
        case .crown: "crown.fill"
        case .trophy: "trophy.fill"
        case .moneyBag: "bag.fill"
        case .dollarSign: "dollarsign.circle.fill"
        case .clover: "camera.macro.circle.fill"
        case .blossom: "fan.fill"
        case .pottedPlant: "leaf.circle.fill"
        case .maple: "tree.fill"
        case .wiltedFlower: "wind"
        case .butterfly: "sparkles"
        case .snail: "tortoise.fill"
        case .caterpillar: "ant.fill"
        case .spider: "ant.circle.fill"
        case .bee: "ladybug.circle.fill"
        }
    }

    var title: String {
        switch self {
        case .sword: "Sword"
        case .waterDrop: "Drop"
        case .skull: "Skull"
        case .toadstool: "Toadstool"
        case .moon: "Moon"
        case .lightning: "Bolt"
        case .leaf: "Leaf"
        case .heart: "Heart"
        case .fire: "Fire"
        case .compass: "Compass"
        case .bunny: "Bunny"
        case .dog: "Dog"
        case .frog: "Frog"
        case .goat: "Goat"
        case .cat: "Cat"
        case .diamond: "Diamond"
        case .crown: "Crown"
        case .trophy: "Trophy"
        case .moneyBag: "Money"
        case .dollarSign: "Dollar"
        case .clover: "Clover"
        case .blossom: "Blossom"
        case .pottedPlant: "Plant"
        case .maple: "Maple"
        case .wiltedFlower: "Wilted"
        case .butterfly: "Butterfly"
        case .snail: "Snail"
        case .caterpillar: "Caterpillar"
        case .spider: "Spider"
        case .bee: "Bee"
        }
    }
}

/// A swatch's resting ring: light in a dark room, shade in a light one.
private let swatchRing = Color.relative(dark: 0.12, light: 0.14)
