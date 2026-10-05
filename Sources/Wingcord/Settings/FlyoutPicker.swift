import SwiftUI

/// A choice of several, made in a glass flyout rather than a pop-up menu.
///
/// **The control alone, without a row around it**, so a sheet field and a
/// settings row can both carry it. `SettingsFlyoutRow` is this inside a row;
/// the channel Overview's slowmode, bitrate and region are this inside a
/// `SheetField`. One implementation, because two copies of a trough, a chevron
/// and a popover list are two places for the tick to drift.
///
/// **The popover paints no material of its own** — `INVARIANTS.md` §4.9.
struct FlyoutPicker<Value: Hashable>: View {
    @Binding var selection: Value
    var options: [Value]
    var title: (Value) -> String
    var symbol: (Value) -> String? = { _ in nil }
    var detail: (Value) -> String? = { _ in nil }
    /// The control's name for VoiceOver — the field it sits in.
    var accessibilityTitle: String
    var isEnabled = true
    var flyoutWidth: CGFloat = 260

    @State private var isShowing = false

    var body: some View {
        Button { isShowing.toggle() } label: {
            HStack(spacing: Spacing.tight) {
                if let symbol = symbol(selection) {
                    Image(symbol: symbol)
                        .font(.system(size: 11))
                        .foregroundStyle(Ink.secondary)
                }
                Text(title(selection))
                    .font(SettingsType.controlLabel)
                    .foregroundStyle(isEnabled ? Ink.primary : Ink.tertiary)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Ink.tertiary)
            }
            .padding(.horizontal, Spacing.base)
            .frame(minHeight: SettingsMetrics.controlRowHeight - Spacing.base)
            .background(SettingsSurface.controlTrough, in: .rect(cornerRadius: Radius.row))
            .contentShape(.rect(cornerRadius: Radius.row))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(Text(accessibilityTitle))
        .accessibilityValue(Text(title(selection)))
        .popover(isPresented: $isShowing, arrowEdge: .bottom) {
            // Capped and scrollable: a region list or a long slowmode set would
            // otherwise draw a flyout taller than the window.
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(options, id: \.self) { option in
                        FlyoutRow(
                            title: title(option),
                            subtitle: detail(option),
                            symbolName: symbol(option),
                            accessory: .tick(option == selection),
                            isSelected: option == selection
                        ) {
                            selection = option
                            isShowing = false
                        }
                    }
                }
                .padding(.vertical, Spacing.tight)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(width: flyoutWidth)
            .frame(maxHeight: FlyoutMetrics.listHeight)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
