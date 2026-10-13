import SwiftUI
import WingcordCore

// MARK: - The soundboard
//
// Discord's picker: "Find the perfect sound" across the top with the volume
// menu beside it, a rail of sections down the left, and the sounds in
// sections — Favorites, Frequently Used, the call's own server, Discord
// Sounds, then every other server (`AppModel.soundboardPresentation` has the
// order and why). The rail scrolls to a section rather than filtering to it,
// and a section's header folds it away.
//
// **The gate is drawn and enforced.** A locked section is **dimmed, never
// hidden** — §5.5: a gate is a statement, and hiding a server's sounds makes
// them look like they do not exist — and a locked sound does nothing when
// pressed, because dimming is a statement and a click is an action. A lock
// rule, Discord's own, separates what plays from what does not. No upsell.
//
// Geometry is Discord's stylesheet's: 148 × 40 sound buttons, eight apart in
// rows of three, under 32-point section headings.
struct SoundboardPicker: View {
    var presentation: SoundboardPresentation
    var actions: SoundboardActions

    @Environment(\.motion) private var motion
    @State private var query = ""
    @State private var collapsed: Set<String> = []
    @FocusState private var isSearchFocused: Bool

    static let width: CGFloat = 540
    static let height: CGFloat = 480
    /// Discord's `.soundButton`.
    private static let cell = CGSize(width: 148, height: 40)
    private static let gap: CGFloat = 8

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(soundboardDivider)
            ScrollViewReader { proxy in
                HStack(spacing: 0) {
                    rail(proxy)
                    Divider().overlay(soundboardDivider)
                    grid
                }
            }
        }
        .frame(width: Self.width, height: Self.height)
    }

    // MARK: The head

    private var header: some View {
        HStack(spacing: Spacing.base) {
            HStack(spacing: Spacing.base) {
                Image(systemName: "magnifyingglass")
                    .font(.system(.footnote, weight: .medium))
                    .foregroundStyle(Ink.tertiary)
                TextField("Find the perfect sound", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(.body))
                    .focused($isSearchFocused)
                    .onSubmit(playFirstMatch)
            }
            .padding(.horizontal, Spacing.snug)
            .frame(height: 34)
            .background { Capsule().fill(Palette.selectionFill) }
            // A hairline, so the field has an edge on a dark ground.
            .overlay { Capsule().strokeBorder(Palette.edge) }
            SoundboardVolumeButton(managedGuildID: presentation.managedGuildID, dismiss: actions.dismiss)
        }
        .padding(Spacing.snug)
        .onAppear { isSearchFocused = true }
    }

    // MARK: The rail

    private func rail(_ proxy: ScrollViewProxy) -> some View {
        ScrollView {
            VStack(spacing: Spacing.base) {
                ForEach(presentation.sections) { section in
                    Button {
                        query = ""
                        collapsed.remove(section.id)
                        withAnimation(motion.standard) { proxy.scrollTo(section.id, anchor: .top) }
                    } label: {
                        railIcon(section)
                    }
                    .buttonStyle(.plain)
                    .opacity(section.isLocked ? 0.55 : 1)
                    .help(section.title)
                    .accessibilityLabel(Text(section.title))
                }
            }
            .padding(.vertical, Spacing.snug)
        }
        .scrollIndicators(.never)
        .frame(width: 56)
    }

    private func railIcon(_ section: SoundboardPresentation.Section) -> some View {
        Group {
            if let url = section.iconURL {
                AvatarView(url: url, monogram: section.monogram, side: 32)
            } else if section.kind == .server {
                Text(section.monogram)
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                    .frame(width: 32, height: 32)
                    .background { Circle().fill(Palette.selectionFill) }
            } else {
                Image(symbol: Self.symbol(for: section.kind))
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(Ink.secondary)
                    .frame(width: 32, height: 32)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if section.isLocked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Ink.secondary)
                    .frame(width: 14, height: 14)
                    .background { Circle().fill(Palette.surface) }
                    .offset(x: 2, y: 2)
            }
        }
        .contentShape(.rect)
    }

    /// Discord's category icons: a star, a clock, its own mark.
    private static func symbol(for kind: SoundboardPresentation.Kind) -> String {
        switch kind {
        case .favorites: "star.fill"
        case .frequentlyUsed: "clock.fill"
        case .search: "magnifyingglass"
        case .defaults, .server: "waveform"
        }
    }

    // MARK: The grid

    private var grid: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                ForEach(visibleSections) { section in
                    if section.id == firstLockedSectionID { lockRule }
                    Section {
                        if !collapsed.contains(section.id) || !query.isEmpty {
                            sounds(in: section)
                        }
                    } header: {
                        sectionHeader(section)
                    }
                    .id(section.id)
                }
            }
            .padding(.bottom, Spacing.margin)
        }
        .scrollIndicators(.automatic)
        .scrollBounceBehavior(.basedOnSize)
        .overlay {
            if visibleSections.isEmpty { emptyState }
        }
        // Self-deafened, server-muted or suppressed: Discord's grid plays
        // nothing then, and says so by being out of reach.
        .opacity(presentation.isSilenced ? 0.4 : 1)
        .allowsHitTesting(!presentation.isSilenced)
        .animation(motion.standard, value: query)
        .animation(motion.standard, value: collapsed)
    }

    private func sounds(in section: SoundboardPresentation.Section) -> some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.fixed(Self.cell.width), spacing: Self.gap), count: 3),
            alignment: .leading,
            spacing: Self.gap
        ) {
            ForEach(section.sounds) { sound in
                SoundCell(sound: sound, actions: actions)
            }
            if let add = section.addSound, query.isEmpty {
                addSoundCell(add)
            }
        }
        .padding(.horizontal, Self.gap)
        .padding(.bottom, Self.gap)
        .opacity(section.isLocked ? 0.55 : 1)
    }

    /// A section's heading, which folds it — Discord's `sectionHeader`.
    private func sectionHeader(_ section: SoundboardPresentation.Section) -> some View {
        Button {
            if collapsed.contains(section.id) { collapsed.remove(section.id) } else { collapsed.insert(section.id) }
        } label: {
            HStack(spacing: Spacing.tight + 2) {
                headerIcon(section)
                Text(section.title)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(1)
                Image(systemName: collapsed.contains(section.id) ? "chevron.right" : "chevron.down")
                    .font(.system(.caption2, weight: .bold))
                    .foregroundStyle(Ink.tertiary)
                if section.isLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(.caption2, weight: .bold))
                        .foregroundStyle(Ink.tertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Self.gap)
            .frame(height: 32)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background { Rectangle().fill(.ultraThinMaterial) }
        .accessibilityLabel(Text(section.title))
        .accessibilityValue(Text(collapsed.contains(section.id) ? "Collapsed" : "Expanded"))
    }

    @ViewBuilder
    private func headerIcon(_ section: SoundboardPresentation.Section) -> some View {
        if let url = section.iconURL {
            AvatarView(url: url, monogram: section.monogram, side: 16)
        } else if section.kind != .server {
            Image(symbol: Self.symbol(for: section.kind))
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(Ink.secondary)
                .frame(width: 16, height: 16)
        }
    }

    /// Discord's rule before the first locked section: a line with a lock.
    private var lockRule: some View {
        HStack(spacing: Spacing.base) {
            Rectangle().fill(soundboardDivider).frame(height: 1)
            Image(systemName: "lock.fill")
                .font(.system(.caption, weight: .bold))
                .foregroundStyle(Ink.secondary)
                .frame(width: 26, height: 26)
                .background { Circle().fill(Palette.selectionFill) }
            Rectangle().fill(soundboardDivider).frame(height: 1)
        }
        .padding(.horizontal, Self.gap)
        .padding(.vertical, Self.gap)
        .accessibilityHidden(true)
    }

    /// Discord's Add Sound — to the server's Soundboard page, or inert with
    /// Discord's reason where the reader may not add.
    private func addSoundCell(_ add: SoundboardPresentation.AddSound) -> some View {
        Button {
            actions.addSound(add.guildID)
        } label: {
            HStack(spacing: Spacing.tight) {
                Image(systemName: "plus.circle.fill")
                Text("Add Sound")
                    .font(.system(.footnote, weight: .semibold))
            }
            .foregroundStyle(add.canAdd ? Ink.secondary : Ink.quaternary)
            .frame(width: Self.cell.width, height: Self.cell.height)
            .background {
                RoundedRectangle(cornerRadius: Radius.row + 2, style: .continuous)
                    .strokeBorder(Palette.edge, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!add.canAdd)
        .help(add.canAdd ? "Upload sound for \(add.guildName)"
            : "You don't have permissions to upload sounds to this server.")
        .accessibilityLabel(Text("Upload sound for \(add.guildName)"))
    }

    private var emptyState: some View {
        Group {
            if presentation.sections.isEmpty {
                ProgressView().controlSize(.small)
            } else {
                Text("No results found")
                    .font(.system(.subheadline))
                    .foregroundStyle(Ink.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Search

    /// Every section, or — while searching — Discord's single "Search Results".
    private var visibleSections: [SoundboardPresentation.Section] {
        guard !query.isEmpty else { return presentation.sections.filter { !$0.sounds.isEmpty || $0.addSound != nil } }
        let needle = query.lowercased()
        var seen = Set<String>()
        let matches = presentation.sections.flatMap(\.sounds).filter {
            $0.name.lowercased().contains(needle) && seen.insert($0.id).inserted
        }
        guard !matches.isEmpty else { return [] }
        return [SoundboardPresentation.Section(
            id: "search", kind: .search, title: "Search Results", iconURL: nil, monogram: "",
            isLocked: false, sounds: matches
        )]
    }

    private var firstLockedSectionID: String? {
        visibleSections.first(where: \.isLocked)?.id
    }

    private func playFirstMatch() {
        guard let sound = visibleSections.first?.sounds.first(where: { !$0.isLocked }) else { return }
        actions.press(sound.id)
    }
}

/// What the picker can ask for.
struct SoundboardActions {
    var press: (String) -> Void
    var preview: (String) -> Void
    var favorite: (String, Bool) -> Void
    var addSound: (GuildID) -> Void
    var dismiss: () -> Void
}

/// One sound — Discord's `.soundButton`: its emoji and its name, centred, and
/// on hover its Preview and its star.
private struct SoundCell: View {
    var sound: SoundboardPresentation.Entry
    var actions: SoundboardActions

    @Environment(\.motion) private var motion
    @State private var isHovering = false

    private var label: String { [sound.emoji, sound.name].compactMap { $0 }.joined(separator: " ") }

    var body: some View {
        Button {
            // **Checked here as well as drawn.** A cell that looks unavailable
            // and still fires sends a request the server refuses, which is
            // worse than either honest answer.
            guard !sound.isLocked else { return }
            actions.press(sound.id)
        } label: {
            HStack(spacing: Spacing.tight + 2) {
                glyph
                Text(sound.name)
                    .font(.system(.footnote, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                if sound.isLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Ink.tertiary)
                }
            }
            .padding(.horizontal, Spacing.base)
            .frame(width: 148, height: 40)
            .contentShape(.rect)
        }
        .buttonStyle(SoundCellStyle(isLocked: sound.isLocked))
        .overlay(alignment: .trailing) {
            if isHovering { secondaryActions }
        }
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.hover, value: isHovering)
        .help(sound.refusal ?? "")
        .accessibilityLabel(Text("Play \(label)"))
        .accessibilityHint(Text(sound.refusal ?? ""))
        .accessibilityActions {
            Button("Preview \(label)") { actions.preview(sound.id) }
            Button(sound.isFavorite ? "Unfavorite \(label)" : "Favorite \(label)") {
                actions.favorite(sound.id, !sound.isFavorite)
            }
        }
    }

    /// Discord's two secondary actions, at the button's end.
    private var secondaryActions: some View {
        HStack(spacing: 2) {
            Button { actions.preview(sound.id) } label: {
                Image(systemName: "speaker.wave.2.fill")
                    .frame(width: 20, height: 20)
                    .contentShape(.rect)
            }
            .help("Preview \(label)")
            Button { actions.favorite(sound.id, !sound.isFavorite) } label: {
                Image(systemName: sound.isFavorite ? "star.fill" : "star")
                    .foregroundStyle(sound.isFavorite ? AnyShapeStyle(Color.yellow) : AnyShapeStyle(Ink.secondary))
                    .frame(width: 20, height: 20)
                    .contentShape(.rect)
            }
            .help(sound.isFavorite ? "Unfavorite \(label)" : "Favorite \(label)")
        }
        .font(.system(.caption2, weight: .semibold))
        .foregroundStyle(Ink.secondary)
        .buttonStyle(.plain)
        .padding(.trailing, Spacing.tight)
        .transition(.opacity)
    }

    @ViewBuilder
    private var glyph: some View {
        if let url = sound.emojiURL {
            RemoteImage(url: url, side: 20) { EmptyView() }
                .frame(width: 20, height: 20)
        } else if let emoji = sound.emoji, !emoji.isEmpty {
            Text(emoji).font(.system(.title3))
        }
    }
}

/// A cell that responds on press and says when it cannot.
///
/// A custom style rather than `.plain` with a hover fill, because a locked cell
/// must not dip: a control that animates under the pointer and then does nothing
/// is the inert control §5.5 is about.
private struct SoundCellStyle: ButtonStyle {
    var isLocked: Bool
    @Environment(\.motion) private var motion
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: Radius.row + 2, style: .continuous)
                    .fill(fill(pressed: configuration.isPressed))
            }
            .opacity(isLocked ? 0.45 : 1)
            .scaleEffect(configuration.isPressed && !isLocked ? Motion.pressScale : 1)
            .onHover { hovering in
                guard isHovering != hovering else { return }
                isHovering = hovering
            }
            .animation(motion.hover, value: isHovering)
            .animation(motion.hover, value: configuration.isPressed)
    }

    private func fill(pressed: Bool) -> Color {
        if isLocked { return Palette.surfaceRaised.opacity(0.5) }
        if pressed { return Palette.selectionFill }
        return isHovering ? Palette.hoverFill : Palette.surfaceRaised.opacity(0.7)
    }
}

/// Discord's speaker beside the search: Soundboard Volume, and Server Settings
/// for someone who manages the server's sounds.
private struct SoundboardVolumeButton: View {
    var managedGuildID: GuildID?
    var dismiss: () -> Void

    @Environment(AppModel.self) private var model
    @State private var isOpen = false

    var body: some View {
        Button { isOpen.toggle() } label: {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(.body, weight: .medium))
                .foregroundStyle(Ink.secondary)
                .frame(width: 34, height: 34)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Control volume")
        .accessibilityLabel(Text("Soundboard Volume"))
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            SoundboardVolumeMenu(managedGuildID: managedGuildID) {
                isOpen = false
                dismiss()
            }
        }
    }
}

/// The menu itself — Discord's `user-volume` slider on its volume curve, at
/// most 100, and its "Server Settings" item.
private struct SoundboardVolumeMenu: View {
    var managedGuildID: GuildID?
    var close: () -> Void

    @Environment(AppModel.self) private var model
    /// Where the slider sits: Discord's `M(volume)` — the stored value is a
    /// gain, and the slider shows its position on the curve.
    @State private var position = 1.0
    /// What was last written — restored if the next write is refused, and
    /// what a change is measured against.
    @State private var written: SyncedPreferences?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            VStack(alignment: .leading, spacing: Spacing.tight) {
                HStack {
                    Text("Soundboard Volume")
                        .font(.system(.subheadline, weight: .semibold))
                    Spacer(minLength: Spacing.margin)
                    Text("\(Int((position * 100).rounded()))%")
                        .font(.system(.subheadline).monospacedDigit())
                        .foregroundStyle(Ink.secondary)
                }
                // Written when the slider is let go, and when the menu closes
                // — which is the only end a keyboard or VoiceOver adjustment
                // has.
                Slider(value: $position, in: 0...1) { editing in
                    guard !editing else { return }
                    commit()
                }
                .accessibilityLabel(Text("Soundboard Volume"))
            }
            if let managedGuildID {
                Divider()
                Button("Server Settings") {
                    ServerSettingsWindow.open(managedGuildID, section: .soundboard)
                    close()
                }
                .buttonStyle(.plain)
                .font(.system(.subheadline))
            }
        }
        .padding(Spacing.margin)
        .frame(width: 260)
        .onAppear {
            written = model.syncedPreferences
            position = VolumeCurve.position(ofGain: Double(model.syncedPreferences.soundboardVolume) / 100)
        }
        .onChange(of: position) { _, value in
            let volume = Float(VolumeCurve.gain(atPosition: value) * 100)
            // The curve's round trip is not exact; a hair is not a change.
            guard abs(volume - model.syncedPreferences.soundboardVolume) > 0.01 else { return }
            model.setSoundboardVolume(volume)
        }
        .onDisappear(perform: commit)
    }

    private func commit() {
        guard let written else { return }
        model.commitSoundboardVolume(from: written)
        self.written = model.syncedPreferences
    }
}

/// Reads the catalog and hands the picker a plain value.
///
/// Built inside the popover's own content closure, so a session that never opens
/// the soundboard never builds one — the catalog is a pass over every server's
/// sounds, and the bar it hangs from is evaluated every time somebody starts
/// talking.
struct SoundboardPickerContainer: View {
    var dismiss: () -> Void

    @Environment(AppModel.self) private var model

    var body: some View {
        SoundboardPicker(
            presentation: model.soundboardPresentation,
            actions: SoundboardActions(
                press: { model.pressSound($0) },
                preview: { model.previewSound($0) },
                favorite: { model.setFavoriteSound($0, favorite: $1) },
                addSound: { guildID in
                    ServerSettingsWindow.open(guildID, section: .soundboard)
                    dismiss()
                },
                dismiss: dismiss
            )
        )
        // What is not here yet, asked for as Discord's picker asks — see
        // `VoiceController.soundboardDidOpen`.
        .task { model.soundboardDidOpen() }
        // No material of its own: the popover's glass is the body — §4.9.
        .presentationBackground(.clear)
    }
}

/// The rule under the picker's head: light in a dark room, shade in a light one.
private let soundboardDivider = Color.relative(dark: 0.06, light: 0.08)
