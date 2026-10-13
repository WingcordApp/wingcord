import SwiftUI
import WingcordCore

// MARK: - The sidebar
//
// The system's sidebar list, as the app's Settings has it. Two things differ,
// and both are because this list is about a *server* rather than about the app:
//
//   1. It starts with the server's icon and name, because a window that can be
//      open twice for two servers must say which one this is.
//   2. Its rows are **filtered by what the server is and what the reader may
//      do**, so a section that cannot work is absent rather than dimmed.
//
// Three rows act rather than open — Members, App Directory, Delete Server — and
// they are buttons in the list rather than selectable rows, so the selection
// never lands on a page that does not exist.

struct ServerSettingsSidebar: View {
    let store: ServerSettingsStore
    var guildName: String
    var guildIconURL: URL?
    var isOwner: Bool
    @Binding var selection: ServerSettingsSection
    @Binding var query: String
    /// A row that acts rather than opens. See `ServerSettingsSection.isAction`.
    var act: (ServerSettingsSection) -> Void

    var body: some View {
        let groups = visibleGroups
        let isCommunity = store.settings.value?.isCommunity ?? false
        List(selection: selectionBinding) {
            header
            ForEach(groups, id: \.self) { group in
                if let title = group.header {
                    Section(title) { rows(of: group, isCommunity: isCommunity) }
                } else {
                    Section { rows(of: group, isCommunity: isCommunity) }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $query, placement: .sidebar, prompt: "Search")
        .accessibilityLabel("Server settings sections")
        // A section can disappear underneath the selection: the catalog filters
        // on `GuildSettings`, which arrives after the window opens, and a server
        // that turns out not to have `GUILD_TAGS` loses its Server Tag row a beat
        // later. Landing on the first row that survived is better than a blank
        // detail pane with a highlighted row that is no longer in the list.
        .onChange(of: groups.flatMap(\.sections)) { _, sections in
            let pages = sections.filter { !$0.isAction }
            guard !pages.isEmpty, !pages.contains(selection) else { return }
            selection = pages[0]
        }
        // Onboarding's ON or OFF is read off the sidebar before its page is
        // opened, as Discord's is — and the Welcome Screen is asked beside it,
        // because whether its row exists is the answer.
        .task {
            store.load(.onboarding)
            store.load(.welcomeScreen)
        }
    }

    @ViewBuilder
    private func rows(of group: ServerSettingsSection.Group, isCommunity: Bool) -> some View {
        ForEach(group.sections) { section in
            let label = ServerSettingsSidebarLabel(
                section: section,
                title: section.title(isCommunity: isCommunity),
                decoration: decoration(for: section)
            )
            if section.isAction {
                Button { act(section) } label: { label.contentShape(.rect) }
                    .buttonStyle(.plain)
            } else {
                label.tag(section)
            }
        }
    }

    /// The list's selection, which only ever holds a page.
    private var selectionBinding: Binding<ServerSettingsSection?> {
        Binding(
            get: { selection },
            set: { section in
                if let section, !section.isAction { selection = section }
            }
        )
    }

    /// The server this window is about. Not a row the selection can land on.
    private var header: some View {
        HStack(spacing: Spacing.base) {
            GuildAvatar(url: guildIconURL, name: guildName, side: 24)
            Text(guildName)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.vertical, Spacing.tight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Settings for \(guildName)")
        .accessibilityAddTraits(.isHeader)
    }

    /// Discord's decoration on a row: Onboarding's "ON" or "OFF".
    private func decoration(for section: ServerSettingsSection) -> String? {
        guard section == .onboarding, let onboarding = store.onboarding.value else { return nil }
        return onboarding.isEnabled ? "ON" : "OFF"
    }

    /// The rows this reader may open in this server, with the search applied and
    /// empty groups dropped.
    ///
    /// **Filtered on the settings once they have arrived, and on nothing before
    /// them.** A window that showed no rows for the first two hundred
    /// milliseconds would read as broken; showing every row and then trimming
    /// one reads as the page finishing loading, which is what it is.
    private var visibleGroups: [ServerSettingsSection.Group] {
        let base: [ServerSettingsSection.Group] = if let settings = store.settings.value {
            ServerSettingsSection.groups(
                for: settings,
                permissions: store.permissions,
                isOwner: isOwner,
                hasWelcomeScreen: store.welcomeScreen.value.map { !$0.isEmpty } ?? false
            )
        } else {
            ServerSettingsSection.groups.compactMap { group in
                let kept = group.sections.filter { $0.isReachable(with: store.permissions) && $0 != .deleteServer }
                return kept.isEmpty ? nil : .init(header: group.header, sections: kept)
            }
        }
        guard !query.isEmpty else { return base }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return base }
        let needle = trimmed.lowercased()
        return base.compactMap { group in
            let kept = group.sections.filter { section in
                section.title.lowercased().contains(needle)
                    || section.keywords.contains { $0.contains(needle) }
            }
            return kept.isEmpty ? nil : .init(header: group.header, sections: kept)
        }
    }
}

// MARK: - Row

/// A row's tile and name, and what Discord hangs off its end.
private struct ServerSettingsSidebarLabel: View {
    var section: ServerSettingsSection
    var title: String
    var decoration: String?

    var body: some View {
        Label {
            HStack(spacing: Spacing.tight) {
                Text(title)
                    .foregroundStyle(section == .deleteServer ? AnyShapeStyle(Palette.destructive) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let decoration {
                    Text(decoration)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(decoration == "ON" ? AnyShapeStyle(Palette.affirmative) : AnyShapeStyle(.tertiary))
                }
                // Leaves this window for the main one.
                if section.leavesSettings {
                    Image(systemName: "arrow.up.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
        } icon: {
            SettingsIconTile(
                symbolName: section.symbolName,
                tint: section.tint,
                side: SettingsMetrics.sidebarIconSide,
                radius: SettingsMetrics.sidebarIconRadius
            )
        }
    }
}

// MARK: - The server's mark

/// The icon, or its monogram.
///
/// Its own small view rather than the rail's tile: that one carries an unread
/// pip, a mention badge, a voice ring and a hover-morphing corner radius, none
/// of which mean anything in a settings header.
struct GuildAvatar: View {
    var url: URL?
    var name: String
    var side: CGFloat

    var body: some View {
        RemoteImage(url: url, side: side) {
            Text(monogram)
                .font(.system(size: side * 0.4, weight: .semibold))
                .foregroundStyle(Ink.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(SettingsSurface.card)
        }
        .frame(width: side, height: side)
        .clipShape(.circle)
        .accessibilityHidden(true)
    }

    private var monogram: String {
        let letters = name
            .split(separator: " ", omittingEmptySubsequences: true)
            .compactMap(\.first)
            .prefix(2)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
}
