import SwiftUI
import WingcordCore

/// The full list of what a message offers.
///
/// **A glass flyout, not an `NSMenu`.** The transcript is a drawn canvas so
/// AppKit's own menu path is available — and it would put a system menu, in the
/// system's own vocabulary, over a window that has none anywhere else. What the
/// app has instead is one surface built from the same tokens every other flyout
/// uses.
///
/// **The popover's own glass is its body**, and nothing is painted on it —
/// `INVARIANTS.md` §4.9. A SwiftUI glass drawn on popover content samples
/// the popover's own window, where nothing sits behind it, and comes out as
/// a flat slab; the system's glass samples the app behind the window.
struct MessageMenu: View {
    var groups: [[MessageActionKind]]
    /// What the Apps list would run against. Nil on a surface with no apps
    /// row, which is every menu built without one.
    var appTarget: AppCommandTarget?
    var perform: (MessageActionKind) -> Void
    /// Chosen from the reminder list, which takes over the surface exactly as
    /// the Apps list does. Nil on a surface that does not offer reminders.
    var setReminder: ((ReminderPreset) -> Void)?

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var hovered: MessageActionKind?
    /// Whether the Apps list has taken over the surface.
    ///
    /// **The list swaps rather than a second popover opening**, which is the
    /// rule every other menu in this app follows: one glass body over the
    /// transcript at a time. §4 rule 2.
    @State private var isShowingApps = false
    /// Whether the reminder durations have taken over the surface. Same rule as
    /// `isShowingApps`, and the two are mutually exclusive because each is only
    /// reachable from the root list.
    @State private var isShowingReminders = false
    @State private var hoveredPreset: ReminderPreset?

    static let width: CGFloat = 232
    private static let rowHeight: CGFloat = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isShowingApps, let appTarget {
                ContextCommandList(
                    target: appTarget,
                    back: { isShowingApps = false },
                    run: { model.runContextCommand($0, on: appTarget) }
                )
            } else if isShowingReminders, let setReminder {
                reminderList(setReminder)
            } else {
                ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                    if index > 0 { divider }
                    ForEach(group) { kind in
                        row(kind)
                    }
                }
            }
        }
        .padding(.vertical, Spacing.tight)
        .frame(width: Self.width)
        // No material of its own: the popover's glass is the body — §4.9.
        .animation(motion.fadeQuick, value: hovered)
        .animation(motion.standard, value: isShowingApps)
        .animation(motion.standard, value: isShowingReminders)
    }

    /// The durations, over the same surface.
    ///
    /// The cap is checked here as well as at the act: a free account with a
    /// reminder already set can still open this list, and dimming every row
    /// with a line saying why is a better answer than six rows that all refuse.
    private func reminderList(_ choose: @escaping (ReminderPreset) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { isShowingReminders = false } label: {
                HStack(spacing: Spacing.snug) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 16)
                    Text("Remind Me")
                        .font(.system(.subheadline, weight: .semibold))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Ink.secondary)
                .padding(.horizontal, Spacing.snug)
                .frame(height: Self.rowHeight)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            divider

            if let notice = model.inboxLimitNotice(for: .reminders) {
                Text(notice)
                    .font(.system(.caption))
                    .foregroundStyle(Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Spacing.snug)
                    .padding(.vertical, Spacing.base)
            } else {
                ForEach(ReminderPreset.allCases) { preset in
                    presetRow(preset, choose: choose)
                }
            }
        }
    }

    private func presetRow(
        _ preset: ReminderPreset,
        choose: @escaping (ReminderPreset) -> Void
    ) -> some View {
        Button { choose(preset) } label: {
            HStack(spacing: Spacing.snug) {
                Image(systemName: "clock")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                Text(preset.title)
                    .font(.system(.subheadline))
                    .lineLimit(1)
                Spacer(minLength: Spacing.base)
            }
            .foregroundStyle(hoveredPreset == preset ? Ink.primary : Ink.secondary)
            .padding(.horizontal, Spacing.snug)
            .frame(height: Self.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if hoveredPreset == preset {
                    RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                        .fill(Palette.hoverFill)
                        .padding(.horizontal, Spacing.tight)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isInside in
            let next = isInside ? preset : (hoveredPreset == preset ? nil : hoveredPreset)
            guard next != hoveredPreset else { return }
            hoveredPreset = next
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Ink.quaternary)
            .frame(height: 0.5)
            .padding(.horizontal, Spacing.base)
            .padding(.vertical, Spacing.tight)
    }

    private func row(_ kind: MessageActionKind) -> some View {
        Button {
            // Apps opens the list in place; everything else acts and closes.
            // Both of these open a list in place rather than acting; every
            // other row acts and closes.
            switch kind {
            case .apps: isShowingApps = true
            case .remindMe where setReminder != nil: isShowingReminders = true
            default: perform(kind)
            }
        } label: {
            HStack(spacing: Spacing.snug) {
                Image(systemName: kind.symbolName)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                Text(kind.title)
                    .font(.system(.subheadline))
                    .lineLimit(1)
                Spacer(minLength: Spacing.base)
                if kind.opensSurface {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Ink.tertiary)
                }
            }
            .foregroundStyle(tint(of: kind))
            .padding(.horizontal, Spacing.snug)
            .frame(height: Self.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                // A region inside the flyout's own material rather than a
                // second glass body — §4 rule 2, and the reason the whole menu
                // is one surface.
                if hovered == kind {
                    RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                        .fill(kind.isDestructive
                            ? Palette.destructive.opacity(0.18)
                            : Palette.hoverFill)
                        .padding(.horizontal, Spacing.tight)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isInside in
            let next = isInside ? kind : (hovered == kind ? nil : hovered)
            guard next != hovered else { return }
            hovered = next
        }
    }

    private func tint(of kind: MessageActionKind) -> AnyShapeStyle {
        if kind.isDestructive { return AnyShapeStyle(Palette.destructive) }
        return AnyShapeStyle(hovered == kind ? Ink.primary : Ink.secondary)
    }
}
