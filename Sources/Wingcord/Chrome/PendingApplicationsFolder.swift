import SwiftUI
import WingcordCore

/// Discord's Pending Applications folder (`rc`): an hourglass at the head of
/// the rail that opens into a well of the servers the reader has applied to.
///
/// **Not a `GuildRailFolder`.** That one is a folder of the account's own
/// arrangement — it carries a colour, a member grid, a drag and a menu of its
/// own. This one is none of those: it is not in the settings payload, nothing
/// can be dropped in or out of it, and Discord draws it with a fixed glyph
/// (`pendingFolderButtonIcon`, the hourglass) rather than its members.
///
/// **The one rail element with an inline presentation**, for the reason a
/// toolbar item may have one: it is a single element, evaluated once, not a
/// row repeated down the column — and the coachmark has to point at it.
struct PendingApplicationsFolder: View {
    var folder: PendingApplicationsRail
    var selectedGuildID: GuildID?
    var toggle: () -> Void
    var selectGuild: (GuildID) -> Void
    var openMenu: (GuildID, CGRect) -> Void
    var dismissCoachmark: () -> Void

    @Environment(\.motion) private var motion
    @State private var isHovering = false

    private var side: CGFloat { Metrics.guildTile }

    /// A closed folder holding the open application has to say so, or the
    /// selection disappears — `GuildRailFolder`'s rule.
    private var containsSelection: Bool {
        guard let selectedGuildID else { return false }
        return folder.guilds.contains { $0.id == selectedGuildID }
    }

    var body: some View {
        VStack(spacing: Spacing.base) {
            Button(action: toggle) {
                ZStack(alignment: .leading) {
                    RailIndicator(isSelected: !folder.isOpen && containsSelection, hasUnread: false)

                    Image(systemName: "hourglass")
                        .font(.system(size: side * 0.36, weight: .medium))
                        .foregroundStyle(Ink.primary)
                        .frame(width: side, height: side)
                        .background(
                            isHovering ? Palette.hoverFill : Palette.surfaceRaised,
                            in: .rect(cornerRadius: 14, style: .continuous)
                        )
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                // The whole column is the target, as every tile's is.
                .frame(width: Proportions.railWidth, height: side)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                guard hovering != isHovering else { return }
                isHovering = hovering
            }
            .animation(motion.hover, value: isHovering)
            .railHoverLabel("Pending Applications", isHovered: isHovering)
            .accessibilityLabel(Text("Pending Applications"))
            .accessibilityValue(Text(folder.isOpen ? "Expanded" : "Collapsed"))
            .popover(
                isPresented: Binding(
                    get: { folder.showsCoachmark },
                    set: { if !$0 { dismissCoachmark() } }
                ),
                arrowEdge: .trailing
            ) {
                ApplicationCoachmark(dismiss: dismissCoachmark)
                    .presentationBackground(.clear)
            }

            if folder.isOpen {
                VStack(spacing: Spacing.base) {
                    ForEach(folder.guilds) { guild in
                        GuildRailTile(
                            guild: guild,
                            isSelected: guild.id == selectedGuildID,
                            action: { selectGuild(guild.id) },
                            openMenu: { openMenu(guild.id, $0) }
                        )
                    }
                }
                .padding(.vertical, Spacing.base)
                .background {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.white.opacity(0.10))
                        .padding(.horizontal, 8)
                }
                // The well grows from the tile above it, as a folder's does.
                .transition(.materialize(from: .top))
            }
        }
        .animation(motion.glassMorph, value: folder.isOpen)
    }
}

/// What Discord says on the folder once an application has gone in (`rd`).
///
/// No material of its own: the popover's glass is the body — §4.9.
private struct ApplicationCoachmark: View {
    var dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.margin) {
            VStack(alignment: .leading, spacing: Spacing.snug) {
                Text("Your application is pending!")
                    .font(.system(.headline))
                    .foregroundStyle(Ink.primary)
                Text("The server admin will get back to you soon.")
                    .font(.system(.caption))
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(action: dismiss) {
                Text("Got it")
                    .font(.system(.callout, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.capsule)
            .tint(Palette.accent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .padding(Spacing.margin)
        .frame(width: 256)
    }
}
