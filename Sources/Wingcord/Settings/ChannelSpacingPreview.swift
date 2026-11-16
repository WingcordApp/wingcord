import SwiftUI

/// A few rows of a channel list at the spacing being chosen — Settings ›
/// Appearance › Channel list.
///
/// **The list's own measurements, not a picture of them.** Each row is the
/// sidebar's content height for this spacing (`SidebarListSpacing`) plus the
/// system list's inset above and below, and each heading carries the room
/// the sidebar puts over it — so what the sliders show here is what the
/// sidebar beside the window does at the same moment.
struct ChannelSpacingPreview: View {
    var spacing: SidebarListSpacing

    @Environment(\.motion) private var motion

    private static let sections: [(title: String, channels: [String])] = [
        ("INFORMATION", ["rules", "announcements"]),
        ("CHAT", ["general", "clips", "help"]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(Self.sections.enumerated()), id: \.offset) { index, section in
                heading(section.title)
                ForEach(section.channels, id: \.self) { name in
                    row(name, isSelected: index == 1 && name == "general")
                }
            }
        }
        .padding(.horizontal, Spacing.base + Spacing.hair)
        .padding(.vertical, Spacing.base)
        .frame(maxWidth: 320, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Radius.glass, style: .continuous)
                .fill(SettingsSurface.card.opacity(0.6))
        )
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.tight)
        .animation(motion.standard, value: spacing)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Preview of the channel list at this spacing"))
    }

    private func heading(_ title: String) -> some View {
        HStack(spacing: Spacing.tight) {
            Image(systemName: "chevron.down")
                .font(.system(.caption2, weight: .bold))
            Text(title)
                .font(Typeface.categoryHeader)
        }
        .foregroundStyle(Ink.secondary)
        .padding(.top, spacing.categoryTop)
        .padding(.leading, Spacing.tight)
        .frame(height: spacing.categoryTop + Metrics.sidebarRowContent, alignment: .bottom)
    }

    private func row(_ name: String, isSelected: Bool) -> some View {
        HStack(spacing: Spacing.base) {
            Image(systemName: "number")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Ink.tertiary)
                .frame(width: 18)
            Text(name)
                .font(.system(.body, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Ink.primary : Ink.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.base)
        .frame(height: spacing.channelRowContent)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                    .fill(Ink.primary.opacity(0.12))
            }
        }
        .padding(.vertical, Metrics.sidebarRowInset)
    }
}
