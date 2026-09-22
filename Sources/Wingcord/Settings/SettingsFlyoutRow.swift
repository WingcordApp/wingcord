import SwiftUI

/// A settings row whose choice is made in a **flyout**, not a pop-up menu.
///
/// **The house answer for a choice of more than two.** A `Picker(.menu)` brings
/// AppKit's own menu: a different material, a different corner, a different row
/// height and a different type size from every other surface this app opens, and
/// beside the app's own panels it reads as a control that wandered in from
/// another program. A flyout is the vocabulary the conversation menu, the server
/// menu and the rail's right-click already share — see `FlyoutMenu.swift` — so
/// this is one more caller of it rather than a fifth idea.
///
/// Two states stay a `SettingsSegmentedControl`: that is the system's real
/// segmented control, both answers are visible at rest, and a flyout to choose
/// between two things is a click spent on nothing.
///
/// **The popover paints no material of its own** — `INVARIANTS.md` §4.9. On
/// macOS 27 an `NSPopover` draws Liquid Glass at the window level, sampling the
/// app behind it; a `.glassEffect` on its *content* lives inside the popover's
/// own window with nothing to lens and renders as a flat grey slab.
struct SettingsFlyoutRow<Value: Hashable & Identifiable>: View {
    var title: String
    var help: String?
    @Binding var selection: Value
    var options: [Value]
    /// What each option says. A closure rather than a protocol, because the same
    /// value is titled differently in different rows — a redaction is "Show" in
    /// the filter matrix and would be "Shown" in a sentence.
    var titleFor: (Value) -> String
    var symbolFor: (Value) -> String?
    var detailFor: (Value) -> String?

    @State private var isShowing = false

    init(
        _ title: String,
        help: String? = nil,
        selection: Binding<Value>,
        options: [Value],
        title titleFor: @escaping (Value) -> String,
        symbol symbolFor: @escaping (Value) -> String? = { _ in nil },
        detail detailFor: @escaping (Value) -> String? = { _ in nil }
    ) {
        self.title = title
        self.help = help
        _selection = selection
        self.options = options
        self.titleFor = titleFor
        self.symbolFor = symbolFor
        self.detailFor = detailFor
    }

    var body: some View {
        SettingsControlRow(title, help: help) {
            Button { isShowing.toggle() } label: {
                HStack(spacing: Spacing.tight) {
                    if let symbol = symbolFor(selection) {
                        Image(systemName: symbol)
                            .font(.system(size: 11))
                            .foregroundStyle(Ink.secondary)
                    }
                    Text(titleFor(selection))
                        .font(SettingsType.controlLabel)
                        .foregroundStyle(Ink.primary)
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
            .accessibilityLabel(Text(title))
            .accessibilityValue(Text(titleFor(selection)))
            .popover(isPresented: $isShowing, arrowEdge: .bottom) {
                VStack(spacing: 0) {
                    ForEach(options) { option in
                        FlyoutRow(
                            title: titleFor(option),
                            subtitle: detailFor(option),
                            symbolName: symbolFor(option),
                            accessory: .tick(option == selection),
                            isSelected: option == selection
                        ) {
                            selection = option
                            isShowing = false
                        }
                    }
                }
                .padding(.vertical, Spacing.tight)
                .frame(width: Self.flyoutWidth)
            }
        }
    }

    /// Wide enough for the longest thing any of these rows says, and no wider:
    /// a flyout sized to its content jumps in width between two options of a
    /// set, which reads as the menu moving under the pointer.
    private static var flyoutWidth: CGFloat { 260 }
}
