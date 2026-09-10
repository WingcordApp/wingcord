import SwiftUI
import WingcordCore

/// The Apps submenu: what an installed app can do to this message, or to this
/// person.
///
/// **One list, two subjects, two menus.** A message's right-click and a
/// conversation's offer the same surface with a different `CommandKind` — 3
/// for a message, 2 for a person — and building it twice would be two places
/// for the search, the ordering and the empty state to drift apart.
///
/// # Why it is a list and not a picker
///
/// A context command has **no options**: Discord forbids them on types 2 and
/// 3, because a right-click has nowhere to type one. So there is no leaf to
/// flatten, no argument to collect and no composer to send the reader to —
/// which is the whole difference from the `/` flyout, and the reason one click
/// here runs the command outright.
///
/// # It is a region inside the menu, never a second glass body
///
/// It is drawn *into* the flyout that opened it, at the same width, with the
/// same rows. §4 rule 2: a second material over the first is glass on glass,
/// and the menus this appears in already swap their contents rather than
/// stacking popovers.
struct ContextCommandList: View {
    var target: AppCommandTarget
    /// Back to whatever list opened this.
    var back: () -> Void
    var run: (ContextCommand) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var query = ""
    @State private var expanded: ApplicationID?
    @State private var hovered: String?
    @FocusState private var isSearchFocused: Bool

    private static let rowHeight: CGFloat = 30

    var body: some View {
        let groups = model.contextCommandGroups(
            target.kind, in: target.channelID ?? ChannelID(rawValue: 0), matching: query
        )
        let frequent = query.isEmpty
            ? model.frequentContextCommands(
                target.kind, in: target.channelID ?? ChannelID(rawValue: 0)
            )
            : []

        VStack(alignment: .leading, spacing: 0) {
            header
            // **The field is drawn only when there is something to search.**
            // Most accounts have two or three apps with a context command;
            // a search box over four rows is chrome, and one over forty is
            // the only way to find anything.
            if groups.count > 2 || !query.isEmpty { searchField }

            if groups.isEmpty {
                empty
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if !frequent.isEmpty {
                            sectionTitle("Frequently Used")
                            ForEach(frequent) { command in
                                commandRow(command, id: "frequent-\(command.id)", sends: true)
                            }
                            divider
                        }
                        sectionTitle("Apps")
                        ForEach(groups) { group in
                            appRow(group)
                        }
                    }
                }
                // Capped and scrollable past the cap, exactly as the server
                // picker beside it is: an account with thirty apps would
                // otherwise draw a menu taller than the window.
                .frame(maxHeight: 300)
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .animation(motion.fadeQuick, value: hovered)
        .animation(motion.standard, value: expanded)
    }

    // MARK: Parts

    private var header: some View {
        Button(action: back) {
            HStack(spacing: Spacing.snug) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                Text("Apps")
                    .font(.system(.subheadline))
                Spacer(minLength: 0)
            }
            .foregroundStyle(hovered == "back" ? Ink.primary : Ink.secondary)
            .padding(.horizontal, Spacing.snug)
            .frame(height: Self.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { highlight("back") }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { track("back", $0) }
    }

    private var searchField: some View {
        HStack(spacing: Spacing.base) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Ink.tertiary)
            TextField("Search commands", text: $query)
                .textFieldStyle(.plain)
                .font(.system(.subheadline))
                .foregroundStyle(Ink.primary)
                .focused($isSearchFocused)
        }
        .padding(.horizontal, Spacing.base)
        .frame(height: 26)
        .background {
            RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                .fill(Palette.hoverFill)
        }
        .padding(.horizontal, Spacing.snug)
        .padding(.bottom, Spacing.tight)
        .task { isSearchFocused = true }
    }

    private var empty: some View {
        Text(
            query.isEmpty
                ? "No app offers anything here."
                : "Nothing matches."
        )
        .font(.system(.subheadline))
        .foregroundStyle(Ink.tertiary)
        .padding(.horizontal, Spacing.snug)
        .frame(height: Self.rowHeight)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(.caption2, weight: .bold))
            .foregroundStyle(Ink.quaternary)
            .tracking(0.6)
            .padding(.horizontal, Spacing.snug)
            .padding(.top, Spacing.tight)
            .padding(.bottom, 2)
    }

    /// One app, and its commands under it when it has more than one.
    ///
    /// **An app with a single command is one row that runs it.** Discord's own
    /// menu does the same, and the reason is worth stating: a disclosure that
    /// opens onto exactly one row is a click spent on nothing.
    @ViewBuilder
    private func appRow(_ group: ContextCommandGroup) -> some View {
        if group.commands.count == 1, let only = group.commands.first {
            commandRow(only, id: "single-\(group.id.rawValue)", sends: true, icon: group.iconURL)
        } else {
            let id = "app-\(group.id.rawValue)"
            let isOpen = expanded == group.id
            Button {
                expanded = isOpen ? nil : group.id
            } label: {
                HStack(spacing: Spacing.snug) {
                    icon(group.iconURL, monogram: group.name)
                    Text(group.name)
                        .font(.system(.subheadline))
                        .lineLimit(1)
                    Spacer(minLength: Spacing.base)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Ink.tertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .foregroundStyle(hovered == id ? Ink.primary : Ink.secondary)
                .padding(.horizontal, Spacing.snug)
                .frame(height: Self.rowHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background { highlight(id) }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .onHover { track(id, $0) }

            if isOpen {
                ForEach(group.commands) { command in
                    commandRow(
                        command,
                        id: "cmd-\(command.id)",
                        sends: true,
                        indented: true
                    )
                }
            }
        }
    }

    private func commandRow(
        _ command: ContextCommand,
        id: String,
        sends: Bool,
        indented: Bool = false,
        icon iconURL: URL? = nil
    ) -> some View {
        Button { run(command) } label: {
            HStack(spacing: Spacing.snug) {
                if let iconURL {
                    icon(iconURL, monogram: command.name)
                } else if indented {
                    Color.clear.frame(width: 18)
                }
                Text(command.name)
                    .font(.system(.subheadline))
                    .lineLimit(1)
                Spacer(minLength: Spacing.base)
                // The send arrow Discord draws on a command that runs
                // outright — which here is every one of them, because a
                // context command has nothing to fill in.
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(
                        hovered == id
                            ? AnyShapeStyle(Palette.accent)
                            : AnyShapeStyle(Ink.quaternary)
                    )
            }
            .foregroundStyle(hovered == id ? Ink.primary : Ink.secondary)
            .padding(.horizontal, Spacing.snug)
            .padding(.leading, indented ? Spacing.snug : 0)
            .frame(height: Self.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { highlight(id) }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { track(id, $0) }
        .accessibilityLabel(Text(command.name))
    }

    private func icon(_ url: URL?, monogram: String) -> some View {
        RemoteImage(url: url, side: 18) {
            Text(String(monogram.prefix(1)).uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Ink.secondary)
                .frame(width: 18, height: 18)
                .background { Circle().fill(Palette.surfaceRaised) }
        }
        .frame(width: 18, height: 18)
        .clipShape(.circle)
    }

    private var divider: some View {
        Rectangle()
            .fill(Ink.quaternary)
            .frame(height: 0.5)
            .padding(.horizontal, Spacing.base)
            .padding(.vertical, Spacing.tight)
    }

    @ViewBuilder
    private func highlight(_ id: String) -> some View {
        if hovered == id {
            RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                .fill(Palette.hoverFill)
                .padding(.horizontal, Spacing.tight)
        }
    }

    private func track(_ id: String, _ isInside: Bool) {
        let next = isInside ? id : (hovered == id ? nil : hovered)
        guard next != hovered else { return }
        hovered = next
    }
}
