import SwiftUI

// MARK: - The vocabulary every glass flyout in this app is built from
//
// **One implementation, because there are now four of them.** The conversation
// menu, the server menu, the rail's right-click and the notification sheet are
// the same object with different contents: a list of rows over a popover's own
// glass, one of which may lead to another list. They had one row helper between
// them copied into each file, and the copies had already drifted — one drew its
// highlight with a `RoundedRectangle` where §4.9 asks for a `ConcentricRectangle`
// so it follows the popover's corners.
//
// **No material, no ground, no shadow** — `INVARIANTS.md` §4.9. The popover
// supplies all three, and a `.glassEffect` painted on its content lives inside
// the popover's own window with nothing behind it to lens. Row highlights are
// the only paint here.

/// What sits at the trailing end of a flyout row.
///
/// A case rather than a generic trailing view: every one of these is drawn the
/// same way at the same size in every flyout, and a `ViewBuilder` parameter
/// would be four call sites free to disagree about it.
enum FlyoutAccessory: Equatable {
    case none
    /// The row opens another list in the same surface.
    case disclosure
    /// A write is in flight.
    case busy
    /// A tick, for the chosen row of a set — Discord's own mute-duration menu.
    case tick(Bool)
    /// A drawn box, for a switch the menu itself carries.
    case checkbox(Bool)
    /// The system's switch, for a settings sheet rendered as a flyout.
    case control(Bool)
    /// A short trailing label — the level a submenu is currently set to.
    case detail(String)
}

/// One row of a glass flyout.
///
/// **Its hover is its own.** The menus this replaces kept a `hovered: String?`
/// on the container, so pointing at any row invalidated the whole menu's body —
/// every row, its title, its icon and any value it read off the model — a dozen
/// times a second while the pointer crossed the list. State here rebuilds one
/// row, and it also removes the ordering fix those containers needed: AppKit can
/// deliver row B's enter before row A's exit, which is what `track(_:_:)` was
/// working around.
struct FlyoutRow: View {
    var title: String
    var subtitle: String?
    /// Nil draws no glyph **and reserves no room for one**, so a list with no
    /// icons at all sits flush rather than indented past an empty gutter.
    var symbolName: String?
    /// A brand's mark in the glyph's place — a store, a connection — drawn by
    /// `ConnectionMark`, which falls back to a symbol for a brand it has none
    /// for. Wins over `symbolName`.
    var brandService: String?
    var accessory: FlyoutAccessory = .none
    var isDestructive = false
    var isEnabled = true
    /// Drawn in the accent rather than the ink hierarchy — the row the reader
    /// is on, in a list that is also a picker.
    var isSelected = false
    var act: () -> Void

    @Environment(\.motion) private var motion
    @State private var isHovering = false

    var body: some View {
        Button(action: act) {
            HStack(spacing: Spacing.snug) {
                if let brandService {
                    ConnectionMark(service: brandService, side: 16)
                } else if let symbolName {
                    Image(systemName: symbolName)
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 16)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.system(.subheadline))
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(.caption2))
                            .foregroundStyle(Ink.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: Spacing.base)
                accessoryView
            }
            .foregroundStyle(tint)
            .padding(.horizontal, Spacing.snug)
            // Taller where a subtitle rides under the title, so the two lines
            // are not crushed into one row's height. A minimum rather than a
            // fixed height: a reader who has raised their text size gets a
            // taller row, not a clipped one.
            .frame(minHeight: subtitle == nil ? FlyoutMetrics.rowHeight : 40)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { highlight }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || accessory == .busy)
        .onHover { hovering in
            // A `@State` write of an equal value still invalidates.
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.fadeQuick, value: isHovering)
    }

    @ViewBuilder
    private var accessoryView: some View {
        switch accessory {
        case .none:
            EmptyView()
        case .disclosure:
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Ink.tertiary)
        case .busy:
            ProgressView().controlSize(.small)
        case .tick(let isOn):
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Palette.accent)
                .opacity(isOn ? 1 : 0)
        case .checkbox(let isOn):
            FlyoutCheckbox(isOn: isOn)
        case .control(let isOn):
            // The system's own switch, drawn but not driven: the row is the
            // control, and a live `Toggle` inside a `Button` is two hit regions
            // arguing over one gesture.
            Toggle("", isOn: .constant(isOn))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.mini)
                .allowsHitTesting(false)
        case .detail(let text):
            Text(text)
                .font(.system(.caption))
                .foregroundStyle(Ink.tertiary)
                .lineLimit(1)
        }
    }

    private var tint: AnyShapeStyle {
        if !isEnabled { return AnyShapeStyle(Ink.quaternary) }
        if isDestructive { return AnyShapeStyle(Palette.destructive) }
        if isSelected { return AnyShapeStyle(Ink.primary) }
        return AnyShapeStyle(isHovering ? Ink.primary : Ink.secondary)
    }

    /// **`ConcentricRectangle`, so the highlight follows the popover's own
    /// corners** rather than a radius this file picked — §4.9. Inset on both
    /// sides so it reads as a pill inside the list rather than a band across it.
    @ViewBuilder
    private var highlight: some View {
        if isHovering && isEnabled {
            ConcentricRectangle()
                .fill(isDestructive ? Palette.destructive.opacity(0.18) : Palette.hoverFill)
                .padding(.horizontal, Spacing.tight)
        }
    }
}

/// Discord's checkbox, for the two switches its server menu carries inline.
///
/// A drawn box rather than the system's — this is a *menu* item, and a macOS
/// switch at menu-row height out-weighs every other row in the list. The tick is
/// SF Symbols'; only the box is drawn.
private struct FlyoutCheckbox: View {
    var isOn: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(isOn ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(.clear))
            .strokeBorder(
                isOn ? AnyShapeStyle(.clear) : AnyShapeStyle(Ink.quaternary),
                lineWidth: 1.5
            )
            .frame(width: 16, height: 16)
            .overlay {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .opacity(isOn ? 1 : 0)
            }
            .accessibilityHidden(true)
    }
}

/// The hairline between groups of rows.
struct FlyoutDivider: View {
    var body: some View {
        Rectangle()
            .fill(Ink.quaternary)
            .frame(height: 0.5)
            .padding(.horizontal, Spacing.base)
            .padding(.vertical, Spacing.tight)
            .accessibilityHidden(true)
    }
}

/// The row that takes a nested list back to the one that opened it.
struct FlyoutBackRow: View {
    var title: String
    var act: () -> Void

    @Environment(\.motion) private var motion
    @State private var isHovering = false

    var body: some View {
        Button(action: act) {
            HStack(spacing: Spacing.base) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .bold))
                Text(title)
                    .font(.system(.subheadline, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isHovering ? Ink.primary : Ink.secondary)
            .padding(.horizontal, Spacing.snug)
            .frame(minHeight: FlyoutMetrics.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isHovering {
                    ConcentricRectangle()
                        .fill(Palette.hoverFill)
                        .padding(.horizontal, Spacing.tight)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.fadeQuick, value: isHovering)
    }
}

/// A caption under a switch, in the sheets Discord writes copy for.
struct FlyoutCaption: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.system(.caption))
            .foregroundStyle(Ink.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.snug)
            .padding(.bottom, Spacing.base)
    }
}

/// A small heading over a group of rows.
struct FlyoutSectionHeader: View {
    var title: String

    var body: some View {
        Text(title)
            .font(.system(.caption, weight: .semibold))
            .foregroundStyle(Ink.tertiary)
            .textCase(.uppercase)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.snug)
            .padding(.top, Spacing.base)
            .padding(.bottom, Spacing.tight)
            .accessibilityAddTraits(.isHeader)
    }
}

/// One line of explanation where a list would otherwise be empty.
struct FlyoutEmpty: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.system(.subheadline))
            .foregroundStyle(Ink.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Spacing.snug)
            .frame(minHeight: FlyoutMetrics.rowHeight, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

nonisolated enum FlyoutMetrics {
    /// A menu row. Shorter than `Metrics.row`, which is a *list* row: a menu is
    /// read in one glance and a list is scrolled.
    static let rowHeight: CGFloat = 30

    /// How tall a scrolling list inside a flyout may get before it scrolls.
    ///
    /// An account with ninety-seven servers or a server with four hundred
    /// channels would otherwise draw a menu taller than the window.
    static let listHeight: CGFloat = 260
}
