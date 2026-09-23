import SwiftUI
import WingcordCore

// MARK: - The soundboard
//
// A rail of servers down the left, a search field across the top, and the sounds
// grouped by where they came from — the shape the expression picker already
// uses, because a reader who has learned one should not have to learn the other.
//
// **The gate is the same one the emoji picker enforces and it is written the
// same way.** Discord's own six are free to everybody, everywhere. A server's
// own sounds are free *in that server*; anywhere else they are the subscription
// perk. A locked section is **dimmed and unpickable, never hidden** — §5.5: a
// gate is a statement, and hiding a server's sounds makes them look like they do
// not exist. And the gate is checked where the press happens as well as where it
// is drawn, because dimming is a statement and a click is an action.
struct SoundboardPicker: View {
    var presentation: SoundboardPresentation
    var press: (String) -> Void
    var dismiss: () -> Void

    @Environment(\.motion) private var motion
    @State private var query = ""
    @State private var selectedSectionID: String?
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            rail
            Divider().overlay(soundboardDivider)
            VStack(spacing: 0) {
                search
                grid
            }
        }
        .frame(width: 460, height: 420)
        .background(.clear)
    }

    // MARK: The rail

    private var rail: some View {
        ScrollView {
            VStack(spacing: Spacing.base) {
                ForEach(presentation.sections) { section in
                    railButton(section)
                }
            }
            .padding(.vertical, Spacing.snug)
        }
        .scrollIndicators(.never)
        .frame(width: 52)
    }

    private func railButton(_ section: SoundboardPresentation.Section) -> some View {
        Button {
            withAnimation(motion.standard) { selectedSectionID = section.id }
        } label: {
            Group {
                if let url = section.iconURL {
                    AvatarView(url: url, monogram: section.monogram, side: 30)
                } else {
                    Image(systemName: "waveform")
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(Ink.primary)
                        .frame(width: 30, height: 30)
                        .background { Circle().fill(Palette.selectionFill) }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if section.isLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Ink.secondary)
                        .frame(width: 13, height: 13)
                        .background { Circle().fill(Palette.surface) }
                        .offset(x: 2, y: 2)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .opacity(section.isLocked ? 0.55 : 1)
        .help(section.title)
        .accessibilityLabel(Text(section.title))
    }

    // MARK: Search

    private var search: some View {
        HStack(spacing: Spacing.base) {
            Image(systemName: "magnifyingglass")
                .font(.system(.footnote, weight: .medium))
                .foregroundStyle(Ink.tertiary)
            TextField("Find a sound", text: $query)
                .textFieldStyle(.plain)
                .font(.system(.body))
                .focused($isSearchFocused)
                .onSubmit(playFirstMatch)
        }
        .padding(.horizontal, Spacing.snug)
        .frame(height: 34)
        .background { Capsule().fill(Palette.selectionFill) }
        // A search field never moves, so it picks up no specular response of
        // its own — over near-black that leaves a capsule with no edge at all.
        .specularEdge()
        .padding(Spacing.snug)
        .onAppear { isSearchFocused = true }
    }

    // MARK: The grid

    private var grid: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.margin, pinnedViews: .sectionHeaders) {
                ForEach(visibleSections) { section in
                    Section {
                        LazyVGrid(
                            columns: [
                                GridItem(.flexible(), spacing: Spacing.base),
                                GridItem(.flexible(), spacing: Spacing.base),
                            ],
                            spacing: Spacing.base
                        ) {
                            ForEach(section.sounds) { sound in
                                cell(sound, in: section)
                            }
                        }
                        .padding(.horizontal, Spacing.snug)
                    } header: {
                        header(section)
                    }
                }
            }
            .padding(.bottom, Spacing.margin)
        }
        .scrollIndicators(.automatic)
        .scrollBounceBehavior(.basedOnSize)
        .overlay {
            if visibleSections.isEmpty { emptyState }
        }
        .animation(motion.standard, value: query)
    }

    private func header(_ section: SoundboardPresentation.Section) -> some View {
        HStack(spacing: Spacing.base) {
            Text(section.title.uppercased())
                .font(Typeface.sectionHeader)
                .foregroundStyle(Ink.secondary)
            if section.isLocked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Ink.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.snug)
        .padding(.vertical, Spacing.tight + 2)
        .background { Rectangle().fill(.ultraThinMaterial) }
    }

    private func cell(
        _ sound: SoundboardPresentation.Entry,
        in section: SoundboardPresentation.Section
    ) -> some View {
        Button {
            // **Checked here as well as drawn.** A cell that looks unavailable
            // and still fires sends a request the server refuses, which is worse
            // than either honest answer.
            guard !sound.isLocked else { return }
            press(sound.id)
        } label: {
            HStack(spacing: Spacing.base) {
                glyph(sound)
                Text(sound.name)
                    .font(.system(.subheadline))
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if sound.isLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Ink.tertiary)
                }
            }
            .padding(.horizontal, Spacing.snug)
            .frame(height: 44)
            .contentShape(.rect)
        }
        .buttonStyle(SoundCellStyle(isLocked: sound.isLocked))
        .accessibilityLabel(Text(sound.name))
        .accessibilityHint(Text(sound.isLocked
            ? (SoundboardGate.refusal(
                SoundboardSound(id: sound.id, name: sound.name, guildID: nil),
                hasNitro: presentation.hasNitro,
                inGuild: nil
              ) ?? "Not available")
            : "Play this sound in the call"))
    }

    @ViewBuilder
    private func glyph(_ sound: SoundboardPresentation.Entry) -> some View {
        if let url = sound.emojiURL {
            RemoteImage(url: url, side: 20) { EmptyView() }
                .frame(width: 20, height: 20)
        } else if let emoji = sound.emoji, !emoji.isEmpty {
            Text(emoji).font(.system(size: 17))
        } else {
            Image(systemName: "waveform")
                .font(.system(.footnote, weight: .medium))
                .foregroundStyle(Ink.tertiary)
                .frame(width: 20)
        }
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.base) {
            Image(systemName: "waveform.slash")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Ink.quaternary)
            Text(query.isEmpty ? "No sounds here yet." : "Nothing matches “\(query)”.")
                .font(.system(.subheadline))
                .foregroundStyle(Ink.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Filtering

    private var visibleSections: [SoundboardPresentation.Section] {
        var sections = presentation.sections
        if let selectedSectionID {
            sections = sections.filter { $0.id == selectedSectionID }
        }
        guard !query.isEmpty else { return sections.filter { !$0.sounds.isEmpty } }
        let needle = query.lowercased()
        return sections.compactMap { section in
            let matches = section.sounds.filter { $0.name.lowercased().contains(needle) }
            guard !matches.isEmpty else { return nil }
            var copy = section
            copy.sounds = matches
            return copy
        }
    }

    private func playFirstMatch() {
        guard let sound = visibleSections.first?.sounds.first, !sound.isLocked else { return }
        press(sound.id)
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
            press: { model.pressSound($0) },
            dismiss: dismiss
        )
        // The server the reader is calling from, and nothing else. A section
        // for another server is fetched when it is opened — see
        // `VoiceController.loadSoundboard`.
        .task {
            guard let guildID = model.connectedVoiceChannelID
                .flatMap({ model.channelIndex[$0] })?.guildID else { return }
            model.loadSoundboard(inGuild: guildID)
        }
            // No material of its own: the popover's glass is the body — §4.9.
        .presentationBackground(.clear)
    }
}

/// The rule under the picker's head: light in a dark room, shade in a light one.
private let soundboardDivider = Color.relative(dark: 0.06, light: 0.08)
