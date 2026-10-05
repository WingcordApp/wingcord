import SwiftUI
import WingcordCore

// MARK: - Server Theme
//
// Discord's page (`1e901507`'s `jT`), for a server that may wear a theme: the
// switch, "Select your theme" — Custom Theme, then the ten presets in the
// picker's own order — and what members will see, saved together under
// Discord's unsaved bar. Every word is Discord's (`976665`, `695508`).
//
// **A custom theme is one colour and its intensity**, as Discord's editor
// writes it (`UPDATE_CUSTOM` with `gradientAngle: 0`): `GuildTheme.resolved`
// draws a custom theme only from exactly one colour, so this offers no more.

struct ServerThemePane: View {
    let store: ServerSettingsStore
    let model: AppModel

    @Environment(\.colorScheme) private var colorScheme
    /// The page's edit, or nil while it shows what the server has.
    @State private var draft: GuildTheme?
    /// What the last save answered, until the server's own update arrives.
    @State private var saved: GuildTheme?

    /// What the server wears now.
    private var original: GuildTheme {
        saved ?? model.guilds[store.guildID]?.theme ?? GuildTheme(isEnabled: false)
    }

    private var working: GuildTheme { draft ?? original }
    private var isDirty: Bool { draft != nil && draft != original }
    private var room: ThemeAppearance { colorScheme == .light ? .light : .dark }

    private var isCustom: Bool { !working.colors.isEmpty }
    private var selectedPreset: Int? { isCustom ? nil : working.presetID }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup {
                SettingsCard {
                    DescribedRow(
                        "Enable Server Theme",
                        detail: Text("This changes how your server looks for all members.")
                    ) {
                        Toggle("Enable Server Theme", isOn: Binding(
                            get: { working.isEnabled },
                            set: setEnabled
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                        .tint(SettingsSurface.switchOn)
                    }
                }
            }

            SettingsGroup("Select your theme") {
                picker
            }

            if isCustom {
                SettingsGroup("Custom Theme") {
                    customEditor
                }
            }

            SettingsGroup("Preview") {
                ServerThemePreview(theme: working.isEnabled ? working : nil, room: room)
                SettingsFootnote("Each member's light or dark mode preference will be shown for them.")
            }

            if isDirty {
                UnsavedChangesBar(
                    reset: { draft = nil },
                    save: save
                )
                .padding(.top, Spacing.margin)
            }
        }
        // Somebody else's save reaches here as the server's own update; the
        // page then shows that rather than what this window last sent.
        .onChange(of: model.guilds[store.guildID]?.theme) { saved = nil }
    }

    // MARK: The picker

    private var picker: some View {
        FlowLayout(spacing: Spacing.snug) {
            ThemeTile(
                name: "Custom Theme",
                isSelected: isCustom,
                select: selectCustom
            ) {
                Image(systemName: "paintpalette.fill")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Ink.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(SettingsSurface.controlTrough)
            }
            ForEach(ServerTheme.pickerOrder, id: \.self) { presetID in
                ThemeTile(
                    name: ServerTheme.presetNames[presetID] ?? "",
                    isSelected: selectedPreset == presetID,
                    select: { select(preset: presetID) }
                ) {
                    ServerThemeSwatch(theme: GuildTheme(isEnabled: true, presetID: presetID), room: room)
                }
            }
        }
    }

    // MARK: Custom

    /// One colour and how strongly it is laid over the server — Discord's
    /// "Colors" and "Color Intensity".
    private var customEditor: some View {
        SettingsCard {
            DescribedRow("Colors") {
                ColorPicker(
                    "Colors",
                    selection: Binding(
                        get: { Color(hex: working.colors.first ?? ServerTheme.defaultCustomColor) },
                        set: { color in
                            var next = working
                            next.colors = [color.rgbValue]
                            next.angle = 0
                            draft = next
                        }
                    ),
                    supportsOpacity: false
                )
                .labelsHidden()
            }
            CardDivider()
            DescribedRow("Color Intensity") {
                Slider(
                    value: Binding(
                        get: { working.baseMix },
                        set: { value in
                            var next = working
                            next.baseMix = value.rounded()
                            draft = next
                        }
                    ),
                    in: 0...100
                )
                .frame(width: 180)
                .accessibilityLabel(Text("Color Intensity"))
            }
        }
    }

    // MARK: Acts

    /// Discord's switch (`SET_ENABLED`): on with nothing chosen picks the
    /// picker's first preset.
    private func setEnabled(_ isOn: Bool) {
        var next = working
        next.isEnabled = isOn
        if isOn, next.colors.isEmpty, next.presetID == nil {
            next.presetID = ServerTheme.pickerOrder.first
        }
        draft = next
    }

    /// A preset replaces whatever was chosen, and turns the theme on.
    private func select(preset presetID: Int) {
        draft = GuildTheme(isEnabled: true, presetID: presetID)
    }

    /// Custom keeps a colour already chosen, else starts from Discord's own.
    private func selectCustom() {
        if isCustom {
            var next = working
            next.isEnabled = true
            draft = next
        } else {
            draft = GuildTheme(
                isEnabled: true,
                colors: [ServerTheme.defaultCustomColor],
                angle: 0,
                baseMix: ServerTheme.defaultCustomBaseMix
            )
        }
    }

    private func save() {
        guard let draft else { return }
        Task {
            if let answer = await store.saveServerTheme(draft) {
                saved = answer
                self.draft = nil
            }
        }
    }
}

/// One tile of the picker: its picture in a circle, a ring when it is the one
/// chosen, and its name on hover.
private struct ThemeTile<Picture: View>: View {
    var name: String
    var isSelected: Bool
    var select: () -> Void
    @ViewBuilder var picture: Picture

    private var side: CGFloat { 44 }

    var body: some View {
        Button(action: select) {
            picture
                .frame(width: side, height: side)
                .clipShape(.circle)
                .overlay {
                    Circle().strokeBorder(Palette.hairline, lineWidth: 1)
                }
                .padding(3)
                .overlay {
                    if isSelected {
                        Circle().strokeBorder(Palette.accent, lineWidth: 2)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Palette.accent)
                    }
                }
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(Text(name))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A theme's gradient, as the window would run it for this room.
struct ServerThemeSwatch: View {
    var theme: GuildTheme
    var room: ThemeAppearance

    var body: some View {
        if let resolved = ServerTheme(theme, room: room) {
            let axis = GradientAxis.endpoints(angle: resolved.angle, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            LinearGradient(
                colors: resolved.stops.map { Color(hex: $0) },
                startPoint: UnitPoint(x: axis.start.x, y: axis.start.y),
                endPoint: UnitPoint(x: axis.end.x, y: axis.end.y)
            )
        } else {
            Palette.surfaceRaised
        }
    }
}

/// What members will see: the theme's ground under the two columns its veils
/// and surfaces make — the same numbers the window itself is drawn with — or
/// the plain window when the theme is off.
private struct ServerThemePreview: View {
    var theme: GuildTheme?
    var room: ThemeAppearance

    var body: some View {
        let resolved = theme.flatMap { ServerTheme($0, room: room) }
        ZStack {
            if let theme {
                ServerThemeSwatch(theme: theme, room: room)
            } else {
                Palette.canvas
            }
            HStack(spacing: 6) {
                column(resolved.map { Color(hex: $0.colors.surface).opacity($0.frameVeil) } ?? Palette.surface)
                    .frame(width: 96)
                column(resolved.map { Color(hex: $0.colors.canvas).opacity($0.pageVeil) } ?? Palette.surfaceRaised)
            }
            .padding(10)
        }
        .frame(height: 150)
        .clipShape(.settingsRect(SettingsMetrics.cardRadius))
        .accessibilityElement()
        .accessibilityLabel(Text("Preview"))
    }

    private func column(_ fill: Color) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(fill)
    }
}
