import SwiftUI
import WingcordCore

// The colours a display name style is made of: a well showing every stop at
// once, and the presets almost everybody actually picks from.
//
// **This is a palette control, not a colour picker.** What the system's picker
// cannot do is show four or five stops as one object, and offer a curated set to
// choose between — and that set is the interaction: nobody hand-tunes five prism
// stops. What it *is* excellent at is the leaf, so each stop's handle is a real
// `ColorPicker`: the system panel keeps the eyedropper, the colour spaces, the
// hex field and the accessibility, and this file never reimplements any of them.

/// Every stop of the current style, drawn as one object.
///
/// The stops sit **on** the well rather than beside it, so four colours read as
/// one palette rather than as four unrelated controls in a row — which is what
/// a row of bare `ColorPicker`s looked like.
struct PaletteWell: View {
    var effect: DisplayNameEffect
    @Binding var colors: [Color]

    private static let height: CGFloat = 56
    private static let handle: CGFloat = 30

    var body: some View {
        ZStack {
            fill
            HStack(spacing: Spacing.snug) {
                ForEach(colors.indices, id: \.self) { index in
                    ColorPicker(
                        "Colour \(index + 1) of \(colors.count)",
                        selection: $colors[index],
                        supportsOpacity: false
                    )
                    .labelsHidden()
                    .frame(width: Self.handle, height: Self.handle)
                }
            }
            .padding(.horizontal, Spacing.snug)
        }
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .clipShape(.rect(cornerRadius: Radius.chip, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                .strokeBorder(Palette.railHairline, lineWidth: 1)
        }
    }

    /// **How the stops combine is the effect's own answer**, not one shape for
    /// all of them: Gummy assigns a colour per letter, so its stops are bands
    /// with hard edges, while Gradient and Prism ramp between theirs. Drawing
    /// Gummy as a smooth ramp would preview a blend the renderer never produces.
    @ViewBuilder
    private var fill: some View {
        switch effect {
        case .gummy:
            HStack(spacing: 0) {
                ForEach(colors.indices, id: \.self) { index in
                    Rectangle().fill(colors[index])
                }
            }
        case .gradient, .glow, .prism:
            LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
        case .solid, .neon, .toon, .pop:
            Rectangle().fill(colors.first ?? .clear)
        }
    }
}

/// The curated sets, and the reason the well is usually left alone.
struct PalettePresetRow: View {
    var effect: DisplayNameEffect
    @Binding var colors: [Color]

    @Environment(\.motion) private var motion

    private var presets: [[UInt32]] { effect.presets }
    /// Solids are small circles six to a row; a multi-stop preset needs width to
    /// read as a ramp, so it gets a wider tile and three to a row.
    private var columns: Int { effect.colorCount == 1 ? 6 : 3 }

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.base), count: columns),
            spacing: Spacing.base
        ) {
            ForEach(Array(presets.enumerated()), id: \.offset) { _, preset in
                presetTile(preset)
            }
        }
    }

    private func presetTile(_ preset: [UInt32]) -> some View {
        let swatches = preset.map { Color(hex: $0) }
        let isSelected = colors.map(\.rgbValue) == preset
        return Button {
            colors = swatches
        } label: {
            ZStack {
                if preset.count == 1 {
                    Circle().fill(swatches[0])
                } else if effect == .gummy {
                    HStack(spacing: 0) {
                        ForEach(swatches.indices, id: \.self) { Rectangle().fill(swatches[$0]) }
                    }
                } else {
                    LinearGradient(colors: swatches, startPoint: .leading, endPoint: .trailing)
                }
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        // Over artwork whose brightness is unknown, so the mark
                        // carries its own shadow rather than trusting contrast.
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 2)
                }
            }
            .frame(height: preset.count == 1 ? 30 : 34)
            .clipShape(
                preset.count == 1
                    ? AnyShape(.circle)
                    : AnyShape(.rect(cornerRadius: 8, style: .continuous))
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .animation(motion.hover, value: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel(Text(label(for: preset)))
    }

    private func label(for preset: [UInt32]) -> String {
        preset.count == 1
            ? "Colour \(preset[0].hexLabel)"
            : "\(preset.count)-colour preset starting \(preset[0].hexLabel)"
    }
}

extension UInt32 {
    /// `#RRGGBB`, for a control whose only description is its colour.
    var hexLabel: String { String(format: "#%06X", self) }
}

// MARK: - Discord's own sets

extension DisplayNameEffect {
    /// The presets this effect offers.
    ///
    /// **Measured off Discord's picker, not invented.** Each was sampled from
    /// the preset tiles with that effect selected — band centres for Gummy,
    /// evenly spaced points across the ramp for Gradient and Prism, and the flat
    /// centre for the solids. `BrandColor` sets the precedent this follows: a
    /// palette presented as Discord's has to actually be Discord's, or be
    /// labelled as ours.
    ///
    /// **Neon, Toon and Pop share Solid's twelve**, which is Discord's own
    /// arrangement rather than an economy here — their picker shows the same
    /// grid under all four.
    ///
    /// Sampled from a rendered gradient, so the end stops of the multi-stop sets
    /// are within a unit or two of the authored values; the checked preset in
    /// each capture matches its own well, which is what says the sampling is
    /// reading the right thing.
    var presets: [[UInt32]] {
        switch self {
        case .solid, .neon, .toon, .pop:
            Self.solidPresets.map { [$0] }
        case .gradient, .glow:
            [
                [0x2A_AE_A6, 0xFF_C4_90], [0x2D_B4_6D, 0x8A_E6_F6],
                [0xD9_60_FD, 0x30_7C_E2], [0x8A_44_D5, 0x31_D1_92],
                [0xEF_AF_AD, 0xE5_70_DF], [0xDD_47_3D, 0xBF_8B_F3],
                [0xF4_94_45, 0xE6_5D_DD], [0xDD_5B_29, 0x6C_CF_D9],
            ]
        case .gummy:
            [
                [0xEA_A9_D5, 0xA9_DD_F0, 0xB9_A7_EE, 0xB9_EA_CB],
                [0xFF_6F_C2, 0xF5_4F_A9, 0xFF_9B_D6, 0xD9_6A_B8],
                [0xFF_B5_7A, 0xFF_94_70, 0xFF_7D_79, 0xF0_6B_8A],
                [0xC4_ED_66, 0x99_DE_60, 0x6D_CD_64, 0x45_BD_66],
                [0x7C_B9_FF, 0x8E_E0_D1, 0x9E_95_F6, 0x66_CF_F0],
                [0xD7_7B_FF, 0xB5_6B_FF, 0xE4_5C_E5, 0x8B_6C_FF],
            ]
        case .prism:
            [
                [0x4F_EB_77, 0xFA_E0_48, 0xFF_66_BA, 0x8E_5D_E8, 0x59_65_F2],
                [0xFF_55_36, 0xFF_93_2E, 0xFF_D2_46, 0xFF_66_93, 0xA6_5B_E1],
                [0x93_0F_0A, 0xCE_25_13, 0xF3_58_18, 0xFD_8A_02, 0xFF_BF_30],
                [0x7E_DD_E5, 0x7C_C3_FF, 0x7F_8D_FF, 0xAB_73_FF, 0xDF_80_E4],
                [0x2A_D6_7A, 0x16_D5_BA, 0x20_C6_F4, 0x27_89_FD, 0x56_5C_FF],
                [0xB8_EA_9A, 0xDE_EE_8B, 0xFE_E1_8B, 0xFE_C9_A3, 0xF7_BB_C9],
            ]
        }
    }

    /// The twelve solids, in Discord's own order: six bright, then six deep.
    private static let solidPresets: [UInt32] = [
        0x19_DA_AE, 0x26_E3_6D, 0x1E_98_EC, 0xC4_2A_FF, 0xFD_19_65, 0xC6_A6_14,
        0x0B_9D_7B, 0x0D_AE_4B, 0x0C_6A_A7, 0xA9_13_E5, 0xDA_03_49, 0xFA_37_22,
    ]
}
