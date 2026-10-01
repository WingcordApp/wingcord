import SwiftUI
import WingcordCore

/// A select menu's options — Discord's dropdown, as a flyout off the menu.
///
/// **Each option is Discord's row**: its emoji, its label, and its description
/// under it. A menu that takes one sends the option the moment it is clicked
/// and closes; one that takes several ticks them, stops at its maximum, and
/// sends when the flyout closes — `AppModel.closeSelectMenu`.
///
/// No material of its own: the popover's glass is the body — §4.9.
struct SelectMenuFlyout: View {
    var request: SelectMenuRequest

    @Environment(AppModel.self) private var model

    /// Discord's dropdown is the menu's own width.
    private var width: CGFloat { min(max(request.anchor.width, 240), TimelineMetrics.selectMenuWidth) }

    var body: some View {
        let menu = model.selectMenuComponent(for: request)?.select
        VStack(alignment: .leading, spacing: 0) {
            if let menu {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(menu.options) { option in
                            SelectOptionRow(
                                option: option,
                                isChosen: request.selection.contains(option.value),
                                isSingle: menu.isSingle,
                                isAvailable: menu.isSingle
                                    || request.selection.contains(option.value)
                                    || request.selection.count < menu.maxValues
                            ) {
                                model.toggleSelectOption(option.value)
                            }
                        }
                    }
                    .padding(.vertical, Spacing.tight)
                }
                .frame(maxHeight: FlyoutMetrics.listHeight * 1.5)
                .fixedSize(horizontal: false, vertical: true)
                if !menu.isSingle {
                    FlyoutCaption(text: menu.maxValues >= menu.options.count
                        ? "Choose any. Sent when this closes."
                        : "Choose up to \(menu.maxValues). Sent when this closes.")
                        .padding(.top, Spacing.tight)
                }
            } else {
                FlyoutEmpty(text: "This menu is gone.")
            }
        }
        .frame(width: width)
    }
}

/// One option: Discord's emoji, label and description, with a tick for what
/// is chosen.
struct SelectOptionRow: View {
    var option: SelectMenu.Option
    var isChosen: Bool
    var isSingle: Bool
    /// False for an unchosen option once a menu has all it may take.
    var isAvailable: Bool
    var choose: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: choose) {
            HStack(spacing: Spacing.snug) {
                if let emoji = option.emoji {
                    InlineEmojiMark(emoji: emoji, side: 20)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label)
                        .font(.system(.subheadline, weight: .medium))
                        .foregroundStyle(Ink.primary)
                        .lineLimit(1)
                    if let description = option.description {
                        Text(description)
                            .font(.system(.caption))
                            .foregroundStyle(Ink.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: Spacing.base)
                if isSingle {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Palette.accent)
                        .opacity(isChosen ? 1 : 0)
                } else {
                    Image(systemName: isChosen ? "checkmark.square.fill" : "square")
                        .font(.system(size: 14))
                        .foregroundStyle(isChosen ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(Ink.tertiary))
                }
            }
            .padding(.horizontal, Spacing.snug)
            .padding(.vertical, Spacing.base)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isHovering && isAvailable {
                    ConcentricRectangle()
                        .fill(Palette.hoverFill)
                        .padding(.horizontal, Spacing.tight)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
        .opacity(isAvailable ? 1 : 0.45)
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .accessibilityAddTraits(isChosen ? [.isButton, .isSelected] : .isButton)
    }
}
