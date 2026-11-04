import AppKit
import SwiftUI
import WingcordCore
import UniformTypeIdentifiers

// MARK: - Picking an image
//
// Three pages upload one: the server icon, the tag profile's banner, a webhook's
// avatar. One control, because three file pickers is three places to forget the
// size limit.

/// The picture, then Change and Remove beside it — one row (D10f).
///
/// **An image well, the HIG's way** ("they can also drag in a new image
/// without selecting the well first"): a file dropped anywhere on the row is
/// taken as a pick, and a click on the picture opens the panel the button
/// does. The picture keeps its own shape — a banner is drawn 16:9, not in a
/// square — and an empty one says it can be filled.
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
    /// Width over height. A banner's is 16:9, so its picture is drawn wide.
    var aspectRatio: CGFloat = 1
    /// Whether a GIF is offered at all — an animated icon is a Level 1 perk,
    /// and a GIF picked for a server without it uploads as a still.
    var allowsAnimated = true
    var onPick: (ImageData) -> Void
    /// Nil where there is nothing to remove.
    var onRemove: (() -> Void)?

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.motion) private var motion
    @State private var failure: String?
    @State private var isTargeted = false
    @State private var isHovered = false

    private static let height: CGFloat = 52

    var body: some View {
        HStack(spacing: SettingsMetrics.navigationIconGap) {
            Button(action: pick) { preview }
                .buttonStyle(.plain)
                .onHover { isHovered = $0 }
                .accessibilityLabel(Text(url == nil ? "Choose a picture" : "Change the picture"))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(SettingsType.rowTitle)
                    .foregroundStyle(Ink.primary)
                Text(failure ?? (detail.isEmpty ? dropHint : detail))
                    .font(SettingsType.rowSubtitle)
                    .foregroundStyle(failure == nil ? AnyShapeStyle(Ink.secondary) : AnyShapeStyle(Palette.destructive))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Spacing.base)
            HStack(spacing: Spacing.tight) {
                Button(url == nil ? "Choose\u{2026}" : "Change\u{2026}", action: pick)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                if let onRemove {
                    Button("Remove", role: .destructive, action: onRemove)
                        .buttonStyle(.glass)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                }
            }
        }
        .padding(.leading, SettingsMetrics.navigationIconLeading)
        .padding(.trailing, SettingsMetrics.controlTrailing)
        .padding(.vertical, Spacing.base)
        .frame(maxWidth: .infinity, minHeight: SettingsMetrics.navigationRowHeight)
        .contentShape(.rect)
        .dropDestination(for: URL.self) { urls, _ in
            guard isEnabled, let file = urls.first else { return false }
            drop(file)
            return true
        } isTargeted: { isTargeted = $0 && isEnabled }
        .contextMenu {
            Button(url == nil ? "Choose\u{2026}" : "Change\u{2026}", action: pick)
            if let onRemove {
                Button("Remove", role: .destructive, action: onRemove)
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// Where no line of its own is given: that a file can be dropped here.
    private var dropHint: String {
        url == nil ? "Drop a picture here, or choose one." : "Drop a picture here to replace it."
    }

    private var shape: AnyShape {
        isCircular ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var preview: some View {
        let width = isCircular ? Self.height : (Self.height * aspectRatio).rounded()
        return ZStack {
            if let url {
                RemoteImage(url: url, side: max(width, Self.height)) { placeholder }
            } else {
                placeholder
            }
        }
        .frame(width: width, height: Self.height)
        .clipShape(shape)
        .overlay { rim }
        .scaleEffect(isTargeted ? 1.05 : isHovered && isEnabled ? 1.03 : 1)
        .animation(motion.hover, value: isHovered)
        .animation(motion.glassMorph, value: isTargeted)
        .accessibilityHidden(true)
    }

    /// What the well will do: dashed while it is empty, the accent while a
    /// file hangs over it.
    @ViewBuilder private var rim: some View {
        let color = isTargeted ? Palette.accent : Palette.edge
        let style = StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: url == nil && !isTargeted ? [4, 3] : [])
        if isCircular {
            Circle().strokeBorder(color, style: style)
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(color, style: style)
        }
    }

    private var placeholder: some View {
        ZStack {
            SettingsSurface.controlTrough
            Image(systemName: "photo.badge.plus")
                .font(.system(size: 16))
                .foregroundStyle(Ink.secondary)
        }
    }

    private func pick() {
        Task {
            // Through the shared encoder: a still goes up as PNG and a GIF
            // keeps its frames — what the reference does when it crops.
            guard let file = await ExpressionUpload.pickImages(allowsAnimated: allowsAnimated).first
            else { return }
            failure = nil
            onPick(file.image)
        }
    }

    private func drop(_ file: URL) {
        Task {
            guard let picked = await ExpressionUpload.image(at: file, allowsAnimated: allowsAnimated) else {
                failure = allowsAnimated ? "That isn\u{2019}t a picture this takes." : "That isn\u{2019}t a still picture."
                Haptics.bump()
                return
            }
            failure = nil
            Haptics.tick()
            onPick(picked.image)
        }
    }
}

// MARK: - The banner swatch

/// The colours Discord's Server Profile page offers for `brand_color_primary`.
///
/// **Discord's own nine** (`aA` in module `282435`), by name and in its order.
/// Choosing Soul sent `"#ff1c90"` in the capture, and the other eight are read
/// out of the same table.
///
/// **There are ten tiles, and the first is not one of these.** "Server Icon
/// Color" is the icon's first swatch through the same quantiser a profile's
/// colours come from, and choosing it sends `brand_color_primary: null` — the
/// absence of a brand colour, from which every card then derives one
/// (`updateGuildProfile(id, {brandColorPrimary: null, customBanner: null})`).
enum BrandColor {
    struct Preset: Hashable, Identifiable {
        var name: String
        var value: UInt32
        var id: UInt32 { value }
    }

    static let presets: [Preset] = [
        Preset(name: "Soul", value: 0xFF1C90),
        Preset(name: "Volcano", value: 0xE81D1E),
        Preset(name: "Marsh", value: 0xE86E1D),
        Preset(name: "Thunder", value: 0xE8C02F),
        Preset(name: "Rising", value: 0x71368A),
        Preset(name: "Zephyr", value: 0x029FFC),
        Preset(name: "Cascade", value: 0x4FE2CA),
        Preset(name: "Earth", value: 0x406601),
        Preset(name: "Boulder", value: 0x272727),
    ]
}

/// One banner tile, drawn exactly as the cards draw the banner it chooses:
/// Discord's `n6` glow, the colour brightened at the foot — `GuildBannerArt`.
struct BrandSwatch: View {
    var colour: UInt32
    var name: String
    var isSelected: Bool
    var isEnabled = true
    var choose: () -> Void

    var body: some View {
        Button(action: choose) {
            Canvas { context, size in
                context.withCGContext { cg in
                    GuildBannerArt.drawGlow(colour, in: CGRect(origin: .zero, size: size), context: cg)
                }
            }
            .frame(height: 38)
            .clipShape(.rect(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(
                        isSelected ? InkColor.solid : swatchRing,
                        lineWidth: isSelected ? 2 : 1
                    )
            }
            .contentShape(.rect(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(name)
        .accessibilityLabel(Text(name))
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

/// A discoverable server's own banner artwork, as the grid's last tile —
/// Discord's `Is`. Clicking it uploads; choosing any colour tile clears it.
struct CustomBannerTile: View {
    var url: URL?
    var isSelected: Bool
    var onPick: (ImageData) -> Void

    var body: some View {
        Button(action: pick) {
            ZStack {
                if let url {
                    RemoteImage(url: url, side: 120) { SettingsSurface.controlTrough }
                        .scaledToFill()
                } else {
                    SettingsSurface.controlTrough
                }
                Image(systemName: "pencil")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(radius: 2)
            }
            .frame(height: 38)
            .frame(maxWidth: .infinity)
            .clipShape(.rect(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isSelected ? InkColor.solid : swatchRing, lineWidth: isSelected ? 2 : 1)
            }
            .contentShape(.rect(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help("Upload Banner")
        .accessibilityLabel(Text("Custom banner"))
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private func pick() {
        Task {
            guard let file = await ExpressionUpload.pickImages(allowsAnimated: false).first else { return }
            onPick(file.image)
        }
    }
}

// MARK: - Traits

enum GuildTraitLimits {
    /// Discord's own cap, stated on the page.
    static let maximum = 5
    /// A trait's label, at most — Discord's field caps it at 24.
    static let labelLength = 24
}

/// Discord's five trait slots, each an emoji and up to twenty-four characters.
///
/// **Five fields, always** — Discord's page draws all five whether or not they
/// hold anything, and an empty one is simply not sent (`updateGuildProfile`
/// drops it). Position is the index of what is kept, which is what the
/// captured body sends.
///
/// **A Unicode emoji goes up as its shortcode**, `fire` rather than 🔥 — see
/// `GuildTrait` — so a glyph picked from the picker is turned back into its
/// name before it is stored. A server's custom emoji goes up as its id.
struct TraitEditor: View {
    @Binding var traits: [GuildTrait]
    var isEnabled: Bool
    var commit: () -> Void

    var body: some View {
        VStack(spacing: Spacing.base) {
            ForEach(0..<GuildTraitLimits.maximum, id: \.self) { index in
                TraitSlot(
                    trait: slot(index),
                    number: index + 1,
                    isEnabled: isEnabled,
                    commit: commit
                )
            }
        }
        .padding(SettingsMetrics.cardContentInset)
    }

    /// Slot `index` of five, over a list that may hold fewer.
    private func slot(_ index: Int) -> Binding<GuildTrait> {
        Binding(
            get: { index < traits.count ? traits[index] : GuildTrait(id: index, label: "") },
            set: { value in
                while traits.count <= index {
                    traits.append(GuildTrait(id: traits.count, label: ""))
                }
                traits[index] = value
            }
        )
    }
}

private struct TraitSlot: View {
    @Binding var trait: GuildTrait
    var number: Int
    var isEnabled: Bool
    var commit: () -> Void

    @FocusState private var isFocused: Bool
    /// The label as it stood when the field took focus, so leaving it unchanged
    /// writes nothing.
    @State private var labelOnFocus = ""

    private var isEmpty: Bool { trait.label.isEmpty && trait.emoji == nil && trait.emojiName == nil }

    var body: some View {
        HStack(spacing: Spacing.base) {
            EmojiSlotButton(
                emoji: Binding(
                    get: { trait.emoji },
                    set: { picked in
                        apply(picked)
                        commit()
                    }
                ),
                addLabel: "Add emoji, trait \(number)",
                updateLabel: { "Change emoji, \($0.name), trait \(number)" },
                side: 26,
                isEnabled: isEnabled
            )
            TextField(
                "Trait \(number)",
                text: Binding(
                    get: { trait.label },
                    set: { trait.label = String($0.prefix(GuildTraitLimits.labelLength)) }
                )
            )
            .textFieldStyle(.plain)
            .font(SettingsType.rowLabel)
            .foregroundStyle(Ink.primary)
            .focused($isFocused)
            .disabled(!isEnabled)
            .onSubmit { isFocused = false }
            .onChange(of: isFocused) { _, focused in
                if focused {
                    labelOnFocus = trait.label
                } else if trait.label != labelOnFocus {
                    commit()
                }
            }
            if !isEmpty && isEnabled {
                RowIconButton(symbolName: "xmark", label: "Clear trait \(number)") {
                    trait = GuildTrait(id: trait.id, label: "")
                    commit()
                }
            }
        }
        .padding(.horizontal, Spacing.base)
        .padding(.vertical, 4)
        .background(SettingsSurface.controlTrough, in: .settingsRect(7))
    }

    private func apply(_ picked: EmojiRef?) {
        guard let picked else {
            trait.emojiID = nil
            trait.emojiName = nil
            trait.emojiAnimated = false
            return
        }
        if let id = picked.id {
            trait.emojiID = id
            trait.emojiName = picked.name
            trait.emojiAnimated = picked.isAnimated
        } else {
            trait.emojiID = nil
            trait.emojiName = UnicodeEmoji.shortcode(for: picked.name) ?? picked.name
            trait.emojiAnimated = false
        }
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
    @ModalDismiss private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModalHeader(title: "Games", close: { dismiss() })

            // The system's search field on glass, leading what it searches.
            SearchField(prompt: "Search for a game…", text: $query)
                .padding(.horizontal, Spacing.group)
                .padding(.bottom, Spacing.snug)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if isSearching {
                        LoadingRow()
                    } else if results.isEmpty, !query.isEmpty {
                        Text("No games match your search")
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
        .frame(width: 420, height: 480)
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
                            "Use Boosts to unlock special, themed badge packs for your Server Tag!",
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
                Image(symbol: badge.symbolName)
                    .font(.system(size: 18))
                    .foregroundStyle(isEnabled ? Ink.primary : Ink.tertiary)
                    .frame(height: 24)
                Text(badge.title)
                    .font(.system(.caption2))
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
