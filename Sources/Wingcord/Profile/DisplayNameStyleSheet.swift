import SwiftUI
import WingcordCore
import WingcordNet

/// "Change Display Name Style" — a face, an effect, and the colours the effect
/// takes.
///
/// **The three choices are not independent, and the effect is what binds them.**
/// Solid, Neon, Toon and Pop take one colour; Gradient takes two, Gummy four and
/// Prism five — `DisplayNameEffect.colorCount`, and the captured wire agrees
/// (a live Prism name carries five). So changing the effect changes how many
/// wells there are, and the palette grows or shrinks under it rather than the
/// sheet holding five wells and greying three.
///
/// **The preview is the point of the sheet.** A grid of `Gg` swatches cannot
/// show what a name looks like in a transcript, so the right half renders the
/// reader's own name three times — on their card, in a message, and on their
/// nameplate — which is where they will actually see it.
struct DisplayNameStyleSheet: View {
    var profile: ProfilePresentation
    var current: DisplayNameStyle?
    var apply: (DisplayNameStyle?) -> Void
    var dismiss: () -> Void

    @Environment(\.motion) private var motion
    @State private var font: DisplayNameFont = .default
    @State private var effect: DisplayNameEffect = .solid
    @State private var colors: [Color] = []
    /// **The preview's own appearance, not the app's.** Discord's note says
    /// styles look different across light and dark, and a chooser that could
    /// only show the reader's current mode is a chooser that hides half of what
    /// they are buying.
    @State private var previewIsDark = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Palette.railHairline)
            HStack(alignment: .top, spacing: 0) {
                choices
                Divider().overlay(Palette.railHairline)
                preview
            }
            Divider().overlay(Palette.railHairline)
            footer
        }
        .frame(width: 760, height: 620)
        .background(Palette.surface)
        .clipShape(.rect(cornerRadius: Radius.card, style: .continuous))
        .onAppear { seed() }
    }

    // MARK: Chrome

    private var header: some View {
        HStack {
            Text("Change Display Name Style")
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
            Button("Remove Style") { apply(nil) }
                .buttonStyle(.plain)
                .font(.system(.subheadline, weight: .medium))
                .foregroundStyle(Palette.destructive)
                .padding(.horizontal, Spacing.margin)
                .frame(height: Metrics.control)
                .interactiveChromeOverMedia(in: .rect(cornerRadius: 8, style: .continuous))
                .disabled(current == nil)

            Spacer(minLength: 0)

            Button("Cancel", action: dismiss)
                .buttonStyle(.plain)
                .font(.system(.subheadline, weight: .medium))
                .foregroundStyle(InkColor.primary)
                .padding(.horizontal, Spacing.margin)
                .frame(height: Metrics.control)
                .interactiveChromeOverMedia(in: .rect(cornerRadius: 8, style: .continuous))

            Button("Apply") { apply(draft) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(draft == current)
        }
        .padding(.horizontal, Spacing.group)
        .padding(.vertical, Spacing.snug)
    }

    // MARK: The draft

    private var draft: DisplayNameStyle {
        DisplayNameStyle(font: font, effect: effect, colors: colors.map(\.rgbValue))
    }

    /// Seeds from what is worn, and **fills any colour the effect wants and the
    /// account does not have**. An effect switched from Solid to Prism needs
    /// five wells; four of them have never had a value, and an empty well is a
    /// black name nobody chose.
    private func seed() {
        font = current?.font ?? .default
        effect = current?.effect ?? .solid
        colors = (current?.colors ?? []).map { Color(hex: $0) }
        fitColors()
    }

    private func fitColors() {
        let wanted = effect.colorCount
        if colors.count > wanted {
            colors = Array(colors.prefix(wanted))
        } else if colors.count < wanted {
            // The house accent for the first, then repeats — a new well starts
            // somewhere visible rather than at black.
            let fill = colors.last ?? Color.accentColor
            colors.append(contentsOf: Array(repeating: fill, count: wanted - colors.count))
        }
    }

    // MARK: The left half

    private var choices: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.group) {
                fontGrid
                effectGrid
                colorWells
            }
            .padding(Spacing.group)
        }
        .scrollIndicators(.never)
        .frame(width: 400)
    }

    private var fontGrid: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            heading("Choose Font")
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.snug), count: 4),
                spacing: Spacing.snug
            ) {
                ForEach(DisplayNameFont.allCases, id: \.self) { face in
                    ChoiceTile(isSelected: font == face) { font = face } content: {
                        // **"Gg" in the face itself**, which is the only way a
                        // grid of twelve fonts says anything. A face this build
                        // could not load falls back to the system one, and the
                        // tile says so rather than showing a name in the wrong
                        // face — see `DisplayNameFontRegistry`.
                        Text("Gg")
                            .font(previewFont(face, size: 22))
                            .foregroundStyle(InkColor.primary)
                    }
                    .accessibilityLabel(Text(face.title))
                }
            }
        }
    }

    private var effectGrid: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            heading("Choose Effect")
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.snug), count: 4),
                spacing: Spacing.snug
            ) {
                ForEach(DisplayNameEffect.allCases, id: \.self) { option in
                    ChoiceTile(isSelected: effect == option) {
                        effect = option
                        fitColors()
                    } content: {
                        // **The name rendered in the effect it names**, which is
                        // the same reason the font tiles are set in their own
                        // face: "Gummy" in plain white tells the reader nothing
                        // about what Gummy does. Drawn in the reader's *own*
                        // colours, fitted to that effect's count, so the grid
                        // previews the choice they would actually get rather
                        // than a stock sample.
                        StyledDisplayName(
                            text: option.title,
                            style: DisplayNameStyle(
                                font: .default,
                                effect: option,
                                colors: option.sampleColors
                            ),
                            textStyle: .subheadline,
                            weight: .semibold
                        )
                    }
                    .accessibilityLabel(Text(option.title))
                }
            }
        }
    }

    /// The well, and the sets almost everybody chooses from instead of it.
    private var colorWells: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            heading("Choose Colour")
            PaletteWell(effect: effect, colors: $colors)
            PalettePresetRow(effect: effect, colors: $colors)
            if effect.colorCount > 1 {
                Text("\(effect.title) uses \(effect.colorCount) colours.")
                    .font(Typeface.rowSubtitle)
                    .foregroundStyle(InkColor.tertiary)
            }
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text)
            .font(.system(.subheadline, weight: .semibold))
            .foregroundStyle(InkColor.primary)
    }

    private func previewFont(_ face: DisplayNameFont, size: CGFloat) -> Font {
        DisplayNameFontRegistry.font(face, size: size).map(Font.init)
            ?? .system(size: size, weight: .bold)
    }

    // MARK: The right half

    /// **The three surfaces the name is actually read on**, stacked the way
    /// Discord stacks them: the profile card, a message overlapping its foot,
    /// and the nameplate under that. Overlapping rather than in a column because
    /// the point is that these are *different* materials — a name legible on a
    /// dark card can vanish on a white message row, and seeing them apart hides
    /// exactly that.
    private var preview: some View {
        VStack(alignment: .leading, spacing: 0) {
            previewCard
            messageCard
                .padding(.leading, Spacing.group)
                .offset(y: -Spacing.margin)
                .zIndex(1)
            nameplateRow
                .offset(y: -Spacing.base)
            Spacer(minLength: 0)
            HStack(alignment: .bottom) {
                Text("Colours and effects don't appear inside servers.")
                    .font(Typeface.rowSubtitle)
                    .foregroundStyle(InkColor.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Spacing.snug)
                appearanceToggle
            }
        }
        .padding(Spacing.group)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(motion.fade, value: previewIsDark)
    }

    /// What the preview paints with.
    ///
    /// **Explicit values, not the app's palette.** `Palette.surfaceRaised`
    /// follows the reader's *theme*, so flipping `colorScheme` under it changed
    /// the text colour and left every card dark — a light preview that was only
    /// black text on a dark plate, which is the opposite of what the toggle
    /// promises. These are the two grounds a name is really read on.
    private var ink: PreviewInk { previewIsDark ? .dark : .light }

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(editor(bannerColor))
                .frame(height: 74)
            VStack(alignment: .leading, spacing: 3) {
                StyledDisplayName(
                    text: profile.displayName,
                    style: draft,
                    textStyle: .title2,
                    weight: .bold
                )
                HStack(spacing: 6) {
                    Text(profile.handle)
                        .font(.system(.subheadline))
                        .foregroundStyle(ink.secondary)
                    if let pronouns = profile.pronouns, !pronouns.isEmpty {
                        Text("·").foregroundStyle(ink.secondary)
                        Text(pronouns)
                            .font(.system(.subheadline))
                            .foregroundStyle(ink.secondary)
                    }
                    if let tag = profile.guildTag { GuildTagChip(tag: tag) }
                    if !profile.badges.isEmpty { BadgeRow(badges: profile.badges) }
                }
            }
            .padding(.horizontal, Spacing.margin)
            .padding(.top, 30)
            .padding(.bottom, Spacing.margin)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ink.card)
        }
        .clipShape(.rect(cornerRadius: Radius.glass, style: .continuous))
        // The avatar straddles the banner's foot, which is the arrangement the
        // real card uses — see `ProfileIdentityPanel`.
        .overlay(alignment: .topLeading) {
            AvatarView(
                url: profile.avatarURL,
                monogram: profile.monogram,
                side: 62,
                decorationURL: profile.decorationURL
            )
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(Palette.presenceOnline)
                    .frame(width: 17, height: 17)
                    .overlay { Circle().strokeBorder(ink.card, lineWidth: 3) }
                    .offset(x: 2, y: 2)
            }
            .padding(.leading, Spacing.margin)
            .padding(.top, 42)
        }
        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
    }

    private var messageCard: some View {
        HStack(alignment: .top, spacing: Spacing.snug) {
            AvatarView(
                url: profile.avatarURL,
                monogram: profile.monogram,
                side: Metrics.avatarMessage,
                decorationURL: nil
            )
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    StyledDisplayName(
                        text: profile.displayName,
                        style: draft,
                        textStyle: .subheadline,
                        weight: .semibold
                    )
                    // **9:41 AM** — the time on every iPhone Apple has ever
                    // shown, and a fixed one is what a preview wants: a clock
                    // that ticks while somebody chooses a font is a preview that
                    // redraws for no reason.
                    Text("9:41 AM")
                        .font(.system(size: 11))
                        .foregroundStyle(ink.secondary)
                }
                Text("does anyone read this?")
                    .font(.system(.subheadline))
                    .foregroundStyle(ink.primary)
            }
            Spacer(minLength: 0)
        }
        .padding(Spacing.snug)
        .background {
            RoundedRectangle(cornerRadius: Radius.glass, style: .continuous)
                .fill(ink.message)
        }
        .shadow(color: .black.opacity(0.28), radius: 14, y: 5)
    }

    /// The plate, wearing the reader's own artwork where they have one.
    @ViewBuilder
    private var nameplateRow: some View {
        HStack(spacing: Spacing.snug) {
            AvatarView(
                url: profile.avatarURL,
                monogram: profile.monogram,
                side: 30,
                decorationURL: nil
            )
            StyledDisplayName(
                text: profile.displayName,
                style: draft,
                textStyle: .subheadline,
                weight: .semibold
            )
            if let tag = profile.guildTag { GuildTagChip(tag: tag) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.snug)
        .frame(height: 46)
        .background {
            if let plate = profile.nameplate {
                RemoteImage(url: plate.artworkURL, side: 320, bucket: .artwork) {
                    Color.clear
                }
                .aspectRatio(contentMode: .fill)
            } else {
                ink.message
            }
        }
        .clipShape(.rect(cornerRadius: Radius.chip, style: .continuous))
        .frame(maxWidth: 300, alignment: .leading)
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
    }

    /// The banner's colour in the preview: the reader's own accent where they
    /// have one, and the house accent where they do not — never a flat grey,
    /// because a name is chosen against the colour it will sit on.
    private func editor(_ color: Color?) -> Color { color ?? Color.accentColor }

    private var bannerColor: Color? {
        profile.accentColorValue.map { Color(hex: $0) }
    }

    private var appearanceToggle: some View {
        Picker("Preview appearance", selection: $previewIsDark) {
            Image(systemName: "moon.fill").tag(true)
            Image(systemName: "sun.max.fill").tag(false)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

/// The two grounds the preview paints on.
///
/// Discord's own note says a style looks different across light and dark, and
/// the toggle is there to show it — so these are real surface colours rather
/// than the app's theme tokens, which would follow the reader's own theme and
/// never change under the toggle at all.
private struct PreviewInk {
    var card: Color
    var message: Color
    var primary: Color
    var secondary: Color

    static let dark = PreviewInk(
        card: Color(hex: 0x23_24_28),
        message: Color(hex: 0x2B_2D_31),
        primary: .white,
        secondary: Color(hex: 0xB5_BA_C1)
    )
    static let light = PreviewInk(
        card: Color(hex: 0xFF_FF_FF),
        message: Color(hex: 0xFF_FF_FF),
        primary: Color(hex: 0x06_06_07),
        secondary: Color(hex: 0x5C_5E_66)
    )
}

/// One square in the font or effect grid.
private struct ChoiceTile<Content: View>: View {
    var isSelected: Bool
    var select: () -> Void
    @ViewBuilder var content: () -> Content

    @Environment(\.motion) private var motion

    var body: some View {
        Button(action: select) {
            content()
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background {
                    RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                        .fill(Palette.skeletonPlate)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                        .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
                }
                .contentShape(.rect(cornerRadius: Radius.chip, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(motion.hover, value: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

extension DisplayNameEffect {
    /// The colours a tile draws its own name in.
    ///
    /// **Discord's own samples, fixed — not the reader's current pick.** A grid
    /// tinted with whatever colour is selected changes meaning every time that
    /// colour changes, so it stops being a reference for what the *effect* does.
    /// Holding them still is what lets somebody learn the grid.
    ///
    /// **Measured off Discord's client rather than eyeballed.** Gradient is the
    /// one they publish as CSS —
    /// `linear-gradient(to right bottom, rgb(42,174,166) 10%, rgb(255,196,144) 90%)`
    /// — and the rest were sampled out of the picker's own colour well with the
    /// effect selected, above the eyedropper overlays. Prism repeats, so its two
    /// end samples are blends of the seam and the five stops below are the
    /// unblended ones.
    var sampleColors: [UInt32] {
        switch self {
        case .solid: [0xFF_FF_FF]
        case .gradient: [0x2A_AE_A6, 0xFF_C4_90]
        case .neon: [0x6A_1D_ED]
        case .toon: [0xF4_20_99]
        case .pop: [0x0E_CF_86]
        case .gummy: [0xEA_A9_D5, 0xA9_DD_F0, 0xB9_A7_EE, 0xB9_EA_CB]
        case .prism: [0xFF_93_43, 0x36_ED_7F, 0xFF_E0_48, 0xFF_4D_D2, 0x59_65_F2]
        }
    }
}
