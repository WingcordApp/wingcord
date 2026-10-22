import SwiftUI
import WingcordCore

/// "Change Display Name Style" — a face, an effect, and the colours the effect
/// takes — as a flyout off the name it changes.
///
/// **The three choices are not independent, and the effect is what binds them.**
/// Solid, Neon, Toon and Pop take one colour; Gradient takes two, Gummy four and
/// Prism five — `DisplayNameEffect.colorCount` — so changing the effect changes
/// how many wells there are.
///
/// **Every choice lands in the draft at once**, so the name on the card beside
/// the flyout is the main preview; the one at the top shows it on a dark and a
/// light ground side by side, because Discord's own note says a style looks
/// different across the two and a toggle would only show one at a time.
struct DisplayNameStyleFlyout: View {
    var editor: ProfileEditor

    @Environment(\.motion) private var motion
    /// **Seeded in `init`**, not on appear: a flyout that laid out on the
    /// defaults and then jumped to what is worn drew a frame of the wrong
    /// choices — and laid its rows out for none of the colours.
    @State private var font: DisplayNameFont
    @State private var effect: DisplayNameEffect
    @State private var colours: [UInt32]

    init(editor: ProfileEditor) {
        self.editor = editor
        let seeded = Self.seed(from: editor)
        _font = State(initialValue: seeded.font)
        _effect = State(initialValue: seeded.effect)
        _colours = State(initialValue: seeded.colors)
    }

    private var profile: ProfilePresentation { editor.applied(to: editor.base) }

    var body: some View {
        FlyoutScaffold(title: "Display Name Style", width: 380) {
            Button("Remove", role: .destructive) {
                editor.displayNameStyle = nil
                let seeded = Self.seed(from: editor)
                font = seeded.font
                effect = seeded.effect
                colours = seeded.colors
                Haptics.pop()
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .disabled(editor.displayNameStyle == nil)
        } content: {
            preview
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.margin) {
                    fontGrid
                    effectGrid
                    colourSection
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.never)
            .frame(maxHeight: 440)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: The draft

    private var draft: DisplayNameStyle {
        DisplayNameStyle(font: font, effect: effect, colors: colours)
    }

    /// From what is worn, with any colour the effect wants and the account
    /// lacks filled in — an empty well is a black name nobody chose.
    private static func seed(from editor: ProfileEditor) -> DisplayNameStyle {
        let worn = editor.displayNameStyle
        let effect = worn?.effect ?? .solid
        return DisplayNameStyle(
            font: worn?.font ?? .default,
            effect: effect,
            colors: fitted(worn?.colors ?? [], to: effect, fill: editor.fallbackColour)
        )
    }

    private static func fitted(_ colours: [UInt32], to effect: DisplayNameEffect, fill: UInt32) -> [UInt32] {
        let wanted = effect.colorCount
        if colours.count >= wanted { return Array(colours.prefix(wanted)) }
        return colours + Array(repeating: colours.last ?? fill, count: wanted - colours.count)
    }

    private func fitColours() {
        colours = Self.fitted(colours, to: effect, fill: editor.fallbackColour)
    }

    /// Writes the choice through — the moment it is made.
    private func commit() {
        editor.displayNameStyle = draft
    }

    // MARK: The preview

    private var preview: some View {
        HStack(spacing: Spacing.base) {
            previewChip(ground: Color(hex: 0x23_24_28))
                .environment(\.colorScheme, .dark)
            previewChip(ground: .white)
                .environment(\.colorScheme, .light)
        }
        .animation(motion.fade, value: draft)
    }

    private func previewChip(ground: Color) -> some View {
        HStack(spacing: 6) {
            AvatarView(url: profile.avatarURL, monogram: profile.monogram, side: 22, decorationURL: nil)
            StyledDisplayName(text: profile.displayName, style: draft, textStyle: .subheadline, weight: .bold)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.base)
        .frame(height: 40)
        .frame(maxWidth: .infinity)
        .background(ground, in: .rect(cornerRadius: Radius.row, style: .continuous))
        .accessibilityHidden(true)
    }

    // MARK: The choices

    private var fontGrid: some View {
        section("Font") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.base), count: 4), spacing: Spacing.base) {
                ForEach(DisplayNameFont.allCases, id: \.self) { face in
                    ChoiceTile(isSelected: font == face) {
                        font = face
                        Haptics.tick()
                        commit()
                    } content: {
                        Text("Gg")
                            .font(previewFont(face, size: 20))
                            .foregroundStyle(InkColor.primary)
                    }
                    .accessibilityLabel(Text(face.title))
                }
            }
        }
    }

    private var effectGrid: some View {
        section("Effect") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.base), count: 4), spacing: Spacing.base) {
                ForEach(DisplayNameEffect.offered, id: \.self) { option in
                    ChoiceTile(isSelected: effect == option) {
                        effect = option
                        fitColours()
                        Haptics.tick()
                        commit()
                    } content: {
                        StyledDisplayName(
                            text: option.title,
                            style: DisplayNameStyle(font: .default, effect: option, colors: option.sampleColors),
                            textStyle: .caption,
                            weight: .semibold
                        )
                    }
                    .accessibilityLabel(Text(option.title))
                }
            }
        }
    }

    /// Each stop as one of Wingcord's own wells, then the sets almost
    /// everybody picks from instead.
    private var colourSection: some View {
        section(effect.colorCount > 1 ? "Colours · \(effect.title) uses \(effect.colorCount)" : "Colour") {
            HStack(spacing: Spacing.base) {
                ForEach(colours.indices, id: \.self) { index in
                    ColourWellButton(
                        colour: Binding(
                            get: { colours.indices.contains(index) ? colours[index] : 0 },
                            set: { value in
                                guard colours.indices.contains(index) else { return }
                                colours[index] = value
                                commit()
                            }
                        ),
                        label: colours.count > 1 ? "Colour \(index + 1) of \(colours.count)" : "Name colour",
                        side: 28
                    )
                }
                Spacer(minLength: 0)
            }
            PalettePresetRow(
                effect: effect,
                colors: Binding(
                    get: { colours.map { Color(hex: $0) } },
                    set: { picked in
                        colours = picked.map(\.rgbValue)
                        Haptics.pop()
                        commit()
                    }
                )
            )
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            Text(title)
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(InkColor.primary)
            content()
        }
    }

    private func previewFont(_ face: DisplayNameFont, size: CGFloat) -> Font {
        DisplayNameFontRegistry.font(face, size: size).map(Font.init)
            ?? .system(size: size, weight: .bold)
    }
}

extension DisplayNameEffect {
    /// The colours a tile draws its own name in.
    ///
    /// **Discord's own samples, fixed — not the reader's current pick.** A grid
    /// tinted with whatever colour is selected changes meaning every time that
    /// colour changes, so it stops being a reference for what the *effect* does.
    ///
    /// **Measured off Discord's client rather than eyeballed.** Gradient is the
    /// one they publish as CSS —
    /// `linear-gradient(to right bottom, rgb(42,174,166) 10%, rgb(255,196,144) 90%)`
    /// — and the rest were sampled out of the picker's own colour well with the
    /// effect selected. Prism repeats, so its two end samples are blends of the
    /// seam and the five stops below are the unblended ones.
    var sampleColors: [UInt32] {
        switch self {
        case .solid: [0xFF_FF_FF]
        case .gradient, .glow: [0x2A_AE_A6, 0xFF_C4_90]
        case .neon: [0x6A_1D_ED]
        case .toon: [0xF4_20_99]
        case .pop: [0x0E_CF_86]
        case .gummy: [0xEA_A9_D5, 0xA9_DD_F0, 0xB9_A7_EE, 0xB9_EA_CB]
        case .prism: [0xFF_93_43, 0x36_ED_7F, 0xFF_E0_48, 0xFF_4D_D2, 0x59_65_F2]
        }
    }
}
