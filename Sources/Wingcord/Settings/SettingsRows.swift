import SwiftUI

// MARK: - The row vocabulary
//
// Six row shapes and one card. Every pane in this window is built from these and
// nothing else, which is the whole reason the pages look like one another: a
// pane that needs a seventh shape is a pane that has not decided what it is.
//
// The card is a *container* and the rows are its children, with the caller
// placing the hairlines. That is deliberate rather than clever: the reference
// indents a hairline to clear a row's icon in some cards and runs it full width
// in others, and a card that inserted separators automatically could not do
// both without an argument for every case it might meet.

// MARK: Card

/// A group of rows on one lifted surface.
struct SettingsCard<Content: View>: View {
    /// The BUILT view, not the builder. Storing an escaping `@ViewBuilder` keeps
    /// a closure per instance and stops SwiftUI seeing the content as
    /// structurally stable across updates.
    private let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SettingsSurface.card)
            .clipShape(.settingsRect(SettingsMetrics.cardRadius))
    }
}

/// The hairline between two rows of a card.
struct CardDivider: View {
    /// How far in from the card's leading edge the line starts.
    ///
    /// Sixteen, not the twelve the labels use. Measured off the reference in
    /// both a navigation card and a toggle card, and it is the same in each: the
    /// separator is inset further than the text it separates, which is what
    /// keeps it reading as a division between rows rather than as a rule drawn
    /// across a box. It runs to the card's trailing edge with no inset at all.
    var leading: CGFloat = SettingsMetrics.navigationIconLeading

    var body: some View {
        SettingsSurface.hairline
            .frame(height: SettingsMetrics.hairline)
            .padding(.leading, leading)
    }
}

// MARK: Section header

/// The heading above a card, and the space either side of it.
///
/// The spacing lives here rather than on the enclosing stack because the rhythm
/// is asymmetric — twenty points above, ten below — and a stack with one spacing
/// value cannot express that. A pane therefore stacks its groups at zero spacing
/// and lets each one carry its own air.
struct SettingsGroup<Content: View>: View {
    private let title: String?
    private let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title)
                    .font(SettingsType.sectionHeader)
                    .foregroundStyle(Ink.primary)
                    .padding(.top, SettingsMetrics.cardToHeader)
                    .padding(.bottom, SettingsMetrics.headerToCard)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Info glyph

/// The annotation beside a label.
///
/// A `.help` tooltip rather than a popover: the text is one sentence explaining
/// a setting, the pointer is already on the glyph, and a popover for that is a
/// dismissible window for something the system will show for free.
struct InfoGlyph: View {
    var help: String

    var body: some View {
        Image(systemName: "info.circle.fill")
            .font(.system(size: 12))
            .foregroundStyle(Ink.tertiary)
            .help(help)
            .accessibilityLabel("About this setting")
            .accessibilityHint(help)
    }
}

/// A label with its optional annotation, used by every row that has one.
private struct RowLabel: View {
    var title: String
    var help: String?

    var body: some View {
        HStack(spacing: SettingsMetrics.infoGlyphGap) {
            Text(title)
                .font(SettingsType.rowLabel)
                .foregroundStyle(Ink.primary)
            if let help { InfoGlyph(help: help) }
        }
    }
}

// MARK: Header row

/// A card's first row when the control it labels is on the row below — which is
/// how every segmented control in this window is introduced.
struct CardHeaderRow: View {
    var title: String
    var help: String?

    var body: some View {
        RowLabel(title: title, help: help)
            .padding(.horizontal, SettingsMetrics.cardContentInset)
            .frame(maxWidth: .infinity, minHeight: SettingsMetrics.headerRowHeight, alignment: .leading)
    }
}

// MARK: Control row

/// A label on the left, a control on the right.
struct SettingsControlRow<Control: View>: View {
    private let title: String
    private let help: String?
    private let control: Control

    init(_ title: String, help: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.help = help
        self.control = control()
    }

    var body: some View {
        HStack(spacing: Spacing.snug) {
            RowLabel(title: title, help: help)
            Spacer(minLength: Spacing.base)
            control
        }
        .padding(.leading, SettingsMetrics.cardContentInset)
        .padding(.trailing, SettingsMetrics.controlTrailing)
        .frame(maxWidth: .infinity, minHeight: SettingsMetrics.toggleRowHeight)
    }
}

/// The switch every boolean setting uses.
struct SettingsToggle: View {
    var title: String
    var help: String?
    @Binding var isOn: Bool

    var body: some View {
        SettingsControlRow(title, help: help) {
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                // Small, because the regular switch is 54x24 and the reference's
                // is 44x20 — which is the small one, measured rather than
                // assumed from the name.
                .controlSize(.small)
                .tint(SettingsSurface.switchOn)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: Navigation row

/// A tile, a title, a subtitle and a chevron — the row that opens something.
struct SettingsNavigationRow: View {
    var title: String
    var subtitle: String
    var symbolName: String
    var tint: Color
    var action: () -> Void

    @Environment(\.motion) private var motion
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: SettingsMetrics.navigationIconGap) {
                SettingsIconTile(
                    symbolName: symbolName,
                    tint: tint,
                    side: SettingsMetrics.navigationIconSide,
                    radius: SettingsMetrics.navigationIconRadius
                )
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(SettingsType.rowTitle)
                        .foregroundStyle(Ink.primary)
                    Text(subtitle)
                        .font(SettingsType.rowSubtitle)
                        .foregroundStyle(Ink.secondary)
                }
                Spacer(minLength: Spacing.base)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Ink.tertiary)
            }
            .padding(.leading, SettingsMetrics.navigationIconLeading)
            .padding(.trailing, SettingsMetrics.navigationChevronTrailing)
            .frame(maxWidth: .infinity, minHeight: SettingsMetrics.navigationRowHeight)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(isHovered ? SettingsSurface.rowHover : .clear)
        .onHover { isHovered = $0 }
        .animation(motion.hover, value: isHovered)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Icon tile

/// The rounded, tinted square that carries a symbol.
///
/// The gradient is a single stop of white at the top rather than a second
/// colour: a tile is 20 points across and anything more elaborate than "lit from
/// above" is invisible at that size while costing a second layer.
struct SettingsIconTile: View {
    var symbolName: String
    var tint: Color
    var side: CGFloat
    var radius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(tint.gradient)
            .frame(width: side, height: side)
            .overlay {
                Image(systemName: symbolName)
                    .font(.system(size: side * 0.58, weight: .medium))
                    .foregroundStyle(.white)
            }
    }
}

// MARK: Segmented control

/// The reference's segmented control: equal cells, hairline separators, the
/// selected cell lifted rather than tinted.
///
/// Not `Picker(.segmented)`. The system control is a different height, a
/// different radius and a different selection treatment, and it cannot be made
/// to fill the bottom of a card — the whole point of this shape is that it *is*
/// the card's last row, with its outer corners inherited from the card's clip.
struct SettingsSegmentedControl<Value: Hashable>: View {
    struct Option: Identifiable {
        var value: Value
        /// What the cell says. Empty when the cell is a glyph alone, in which
        /// case it is still the cell's accessibility label.
        var title: String
        var symbolName: String?
        /// A literal character, for the cases where no SF Symbol carries the
        /// meaning — a skin-tone swatch is the only one so far.
        var glyph: String?
        var id: Value { value }

        init(
            _ value: Value,
            _ title: String,
            symbolName: String? = nil,
            glyph: String? = nil,
            spoken: String? = nil
        ) {
            self.value = value
            self.title = title
            self.symbolName = symbolName
            self.glyph = glyph
            self.spoken = spoken
        }

        /// What a screen reader says when the visible label is a glyph.
        var spoken: String?
        var accessibilityTitle: String { spoken ?? title }
    }

    @Binding var selection: Value
    var options: [Option]

    var body: some View {
        HStack(spacing: 0) {
            // `indices`, not `Array(enumerated())`: the latter allocates a
            // second array of pairs on every evaluation to recover an index the
            // range already has.
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                // No separator beside the selected cell: its own lifted fill is
                // the edge there, and drawing both reads as a double rule.
                if index > 0,
                   options[index - 1].value != selection,
                   option.value != selection {
                    SettingsSurface.controlHairline
                        .frame(width: SettingsMetrics.hairline)
                } else if index > 0 {
                    Color.clear.frame(width: SettingsMetrics.hairline)
                }
                Cell(option: option, isSelected: option.value == selection) {
                    selection = option.value
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: SettingsMetrics.controlRowHeight)
        .background(SettingsSurface.controlTrough)
    }

    private struct Cell: View {
        var option: Option
        var isSelected: Bool
        var select: () -> Void
        @Environment(\.motion) private var motion
        @State private var isHovered = false

        var body: some View {
            Button(action: select) {
                HStack(spacing: Spacing.tight + 2) {
                    if let symbolName = option.symbolName {
                        Image(systemName: symbolName)
                            .font(.system(size: 12))
                            .foregroundStyle(isSelected ? Ink.primary : Ink.secondary)
                    }
                    if let glyph = option.glyph {
                        Text(glyph).font(.system(size: 15))
                    }
                    if !option.title.isEmpty {
                        Text(option.title)
                            .font(SettingsType.controlLabel)
                            .foregroundStyle(isSelected ? Ink.primary : Ink.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .background(fill)
            .animation(motion.hover, value: isHovered)
            .animation(motion.standard, value: isSelected)
            .onHover { isHovered = $0 }
            .accessibilityLabel(option.accessibilityTitle)
            .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        }

        private var fill: Color {
            if isSelected { SettingsSurface.controlSelected }
            else if isHovered { SettingsSurface.rowHover }
            else { .clear }
        }
    }
}

// MARK: Slider row

/// A label, a slider and its value. One row, because a slider whose
/// number is on a line of its own is two rows describing one thing.
struct SettingsSliderRow: View {
    var title: String
    var help: String?
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double
    var format: (Double) -> String
    /// True while the knob is held. For a setting whose every change costs a
    /// relayout of the drawn transcript, so the relayout can wait for the
    /// release — see `ThemeStore.beginAdjusting`.
    var onEditingChanged: (Bool) -> Void = { _ in }

    var body: some View {
        SettingsControlRow(title, help: help) {
            HStack(spacing: Spacing.snug) {
                Slider(value: $value, in: range, step: step, onEditingChanged: onEditingChanged)
                    .controlSize(.small)
                    // Neutral, for the same reason the switches are: the accent
                    // is spent on primary buttons, the send arrow and focus
                    // rings, and a settings window is not where it gets spent.
                    .tint(SettingsSurface.switchOn)
                    .frame(width: 180)
                Text(format(value))
                    .font(SettingsType.rowLabel.monospacedDigit())
                    .foregroundStyle(Ink.secondary)
                    .frame(width: 46, alignment: .trailing)
            }
        }
    }
}

// MARK: Value row

/// A label and a read-only value — a version number, a memory footprint.
struct SettingsValueRow: View {
    var title: String
    var value: String
    var help: String?

    var body: some View {
        SettingsControlRow(title, help: help) {
            Text(value)
                .font(SettingsType.rowLabel.monospacedDigit())
                .foregroundStyle(Ink.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: Action row

/// A label and a button. The button carries the glass; the row does not.
struct SettingsActionRow: View {
    var title: String
    var help: String?
    var actionTitle: String
    var role: ButtonRole?
    var action: () -> Void

    init(
        _ title: String,
        help: String? = nil,
        actionTitle: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.help = help
        self.actionTitle = actionTitle
        self.role = role
        self.action = action
    }

    var body: some View {
        SettingsControlRow(title, help: help) {
            Button(actionTitle, role: role, action: action)
                .buttonStyle(.glass)
                .controlSize(.small)
        }
    }
}

// MARK: Footnote

/// The paragraph under a card that explains what it does.
///
/// Outside the card, not inside it: the reference puts explanatory prose in the
/// gap between a card and the next heading, which keeps the card a list of
/// controls and nothing else.
struct SettingsFootnote: View {
    var text: String
    var symbolName: String?

    init(_ text: String, symbolName: String? = nil) {
        self.text = text
        self.symbolName = symbolName
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.base) {
            if let symbolName {
                Image(systemName: symbolName)
                    .font(.system(size: 11))
                    .foregroundStyle(Ink.tertiary)
            }
            Text(text)
                .font(SettingsType.footnote)
                .foregroundStyle(Ink.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, SettingsMetrics.cardContentInset)
        .padding(.top, Spacing.snug)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Hero

/// The icon, name and one-line description at the top of a pane.
///
/// The mark is a view rather than a symbol name, because two of the three heroes
/// in this window are not symbols — one is the app's own artwork and one is the
/// signed-in person's avatar, and a hero that could only draw a tinted tile
/// would need a second hero beside it.
struct SettingsHero<Mark: View>: View {
    private let mark: Mark
    private let title: String
    private let subtitle: String

    init(title: String, subtitle: String, @ViewBuilder mark: () -> Mark) {
        self.title = title
        self.subtitle = subtitle
        self.mark = mark()
    }

    var body: some View {
        VStack(spacing: Spacing.base) {
            mark.shadow(color: .black.opacity(0.35), radius: 10, y: 4)
            VStack(spacing: Spacing.tight) {
                Text(title)
                    .font(SettingsType.heroTitle)
                    .foregroundStyle(Ink.primary)
                Text(subtitle)
                    .font(SettingsType.heroSubtitle)
                    .foregroundStyle(Ink.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, Spacing.base)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Tile row

/// Two or three small cards side by side.
///
/// The reference's About page is built this way, and it works for the same
/// reason a card does: three destinations of equal weight read faster laid out
/// across than stacked, because the eye compares them in one pass instead of
/// three. Anything with a subtitle longer than four words belongs in a
/// navigation row instead.
struct SettingsTileRow<Value: Hashable>: View {
    struct Tile: Identifiable {
        var id: Value
        var title: String
        var caption: String
        var symbolName: String
        var action: () -> Void
    }

    var tiles: [Tile]

    var body: some View {
        HStack(spacing: Spacing.base) {
            ForEach(tiles) { tile in
                TileButton(tile: tile)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private struct TileButton: View {
        var tile: Tile
        @Environment(\.motion) private var motion
        @State private var isHovered = false

        var body: some View {
            Button(action: tile.action) {
                VStack(spacing: Spacing.tight) {
                    Image(systemName: tile.symbolName)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Ink.primary)
                        .frame(height: 22)
                    Text(tile.title)
                        .font(SettingsType.rowTitle.weight(.semibold))
                        .foregroundStyle(Ink.primary)
                    Text(tile.caption)
                        .font(SettingsType.rowSubtitle)
                        .foregroundStyle(Ink.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
                .padding(.vertical, SettingsMetrics.cardContentInset)
                .padding(.horizontal, Spacing.base)
                .frame(maxWidth: .infinity, minHeight: 96)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .background(isHovered ? SettingsSurface.rowHover : SettingsSurface.card)
            .clipShape(.settingsRect(SettingsMetrics.cardRadius))
            .onHover { isHovered = $0 }
            .animation(motion.hover, value: isHovered)
            .accessibilityElement(children: .combine)
        }
    }
}

extension SettingsHero where Mark == SettingsIconTile {
    /// The common case: a tinted tile carrying a symbol.
    init(symbolName: String, tint: Color, title: String, subtitle: String) {
        self.init(title: title, subtitle: subtitle) {
            SettingsIconTile(symbolName: symbolName, tint: tint, side: 64, radius: 15)
        }
    }
}

// MARK: Meter row

/// A label, a value, and a bar showing the value against a ceiling.
///
/// For the one thing in this window that has a ceiling worth seeing: a cache
/// filling toward its capacity. A number alone answers "how much"; the bar
/// answers "how close to full", which is the question somebody reclaiming space
/// is actually asking.
///
/// The bar is drawn only when the ceiling is known and positive — a meter
/// against an unknown maximum is a decoration.
struct SettingsMeterRow: View {
    var title: String
    var help: String?
    var used: Int
    var capacity: Int

    private var fraction: Double {
        guard capacity > 0 else { return 0 }
        return min(1, max(0, Double(used) / Double(capacity)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            HStack(spacing: Spacing.snug) {
                if let help {
                    InfoLabel(title: title, help: help)
                } else {
                    InfoLabel(title: title, help: nil)
                }
                Spacer(minLength: Spacing.base)
                Text(Self.bytes(used) + " of " + Self.bytes(capacity))
                    .font(SettingsType.rowLabel.monospacedDigit())
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(1)
            }
            if capacity > 0 {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(SettingsSurface.controlTrough)
                        Capsule()
                            .fill(SettingsSurface.switchOn)
                            .frame(width: max(fraction > 0 ? 3 : 0, proxy.size.width * fraction))
                    }
                }
                .frame(height: 6)
            }
        }
        .padding(.leading, SettingsMetrics.cardContentInset)
        .padding(.trailing, SettingsMetrics.controlTrailing)
        .padding(.vertical, SettingsMetrics.cardContentInset)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityValue(Self.bytes(used) + " of " + Self.bytes(capacity))
    }

    /// The same style `PerformanceSnapshot` reports memory in, so a figure means
    /// the same thing in both panes.
    static func bytes(_ value: Int) -> String {
        // `ByteCountFormatStyle` writes zero as "Zero kB", which reads as a
        // failure rather than as an empty cache.
        guard value > 0 else { return "Empty" }
        return ByteCountFormatStyle(style: .memory).format(Int64(value))
    }
}

/// A title with its optional annotation. Shared by the rows that are not built
/// on `SettingsControlRow`.
private struct InfoLabel: View {
    var title: String
    var help: String?

    var body: some View {
        HStack(spacing: SettingsMetrics.infoGlyphGap) {
            Text(title)
                .font(SettingsType.rowLabel)
                .foregroundStyle(Ink.primary)
            if let help { InfoGlyph(help: help) }
        }
    }
}
