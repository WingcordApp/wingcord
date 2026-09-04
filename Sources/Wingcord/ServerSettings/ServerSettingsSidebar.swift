import SwiftUI
import WingcordCore

// MARK: - The source list
//
// The same construction as `SettingsSidebar` — hand-rolled rather than a `List`,
// for the reason recorded there: `List` brings AppKit's sidebar vibrancy with it
// and this window is one material edge to edge.
//
// Two things differ, and both are because this list is about a *server* rather
// than about the app:
//
//   1. It has a **header** — the server's icon and name — because a window that
//      can be open twice for two servers must say which one this is. The app's
//      settings window needs no such thing.
//   2. Its rows are **filtered by what the server is and what the reader may
//      do**, so a section that cannot work is absent rather than dimmed.

struct ServerSettingsSidebar: View {
    let store: ServerSettingsStore
    var guildName: String
    var guildIconURL: URL?
    @Binding var selection: ServerSettingsSection
    @Binding var query: String

    @Namespace private var pill
    @Environment(\.motion) private var motion
    @FocusState private var isSearchFocused: Bool
    @FocusState private var isListFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            ServerSettingsSearchField(query: $query, isFocused: $isSearchFocused)
                .padding(.horizontal, SettingsMetrics.sidebarRowInset)
                .padding(.top, Spacing.base)

            ScrollView(.vertical) {
                let groups = visibleGroups
                VStack(alignment: .leading, spacing: SettingsMetrics.sidebarGroupSpacing) {
                    ForEach(groups.indices, id: \.self) { index in
                        VStack(alignment: .leading, spacing: SettingsMetrics.sidebarRowSpacing) {
                            ForEach(groups[index]) { section in
                                ServerSettingsSidebarRow(
                                    section: section,
                                    isSelected: section == selection,
                                    hasKeyboardFocus: isListFocused,
                                    pill: pill
                                ) {
                                    selection = section
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, SettingsMetrics.sidebarRowInset)
                .padding(.top, SettingsMetrics.sidebarListTopInset)
                .padding(.bottom, SettingsMetrics.sidebarRowInset)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(motion.glassMorph, value: selection)
            }
            .scrollBounceBehavior(.basedOnSize)
            .softScrollEdgesVertical()
        }
        // Clipped rather than compressed, so a drag past the minimum slides the
        // labels out of view instead of reflowing every row to two lines.
        .frame(width: SettingsMetrics.sidebarWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Server settings sections")
        .focusable()
        .focusEffectDisabled()
        .focused($isListFocused)
        .onMoveCommand { direction in
            switch direction {
            case .up: step(-1)
            case .down: step(1)
            default: break
            }
        }
        .onKeyPress(keys: ["f"]) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            isSearchFocused = true
            return .handled
        }
        // A section can disappear underneath the selection: the catalog filters
        // on `GuildSettings`, which arrives after the window opens, and a server
        // that turns out not to have `GUILD_TAGS` loses its Server Tag row a beat
        // later. Landing on the first row that survived is better than a blank
        // detail pane with a highlighted row that is no longer in the list.
        .onChange(of: visibleGroups.flatMap(\.self)) { _, sections in
            guard !sections.isEmpty, !sections.contains(selection) else { return }
            selection = sections[0]
        }
    }

    /// The server this window is about.
    ///
    /// Under the traffic lights, which own the top of the column — the same
    /// `searchFieldTop` the app's settings window reserves, spent on a header
    /// here instead of on empty space.
    private var header: some View {
        HStack(spacing: Spacing.base) {
            GuildAvatar(url: guildIconURL, name: guildName, side: 24)
            Text(guildName)
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(Ink.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, SettingsMetrics.sidebarRowInset + 2)
        .padding(.top, SettingsMetrics.searchFieldTop)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Settings for \(guildName)")
    }

    private func step(_ offset: Int) {
        let visible = visibleGroups.flatMap(\.self)
        guard let index = visible.firstIndex(of: selection) else {
            selection = offset >= 0 ? (visible.first ?? selection) : (visible.last ?? selection)
            return
        }
        selection = visible[min(visible.count - 1, max(0, index + offset))]
    }

    /// The rows this reader may open in this server, with the search applied and
    /// empty groups dropped.
    ///
    /// **Filtered on the settings once they have arrived, and on nothing before
    /// them.** A window that showed no rows for the first two hundred
    /// milliseconds would read as broken; showing every row and then trimming
    /// one reads as the page finishing loading, which is what it is.
    private var visibleGroups: [[ServerSettingsSection]] {
        let base: [[ServerSettingsSection]] = if let settings = store.settings.value {
            ServerSettingsSection.groups(for: settings, permissions: store.permissions)
        } else {
            ServerSettingsSection.groups
        }
        guard !query.isEmpty else { return base }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return base }
        let needle = trimmed.lowercased()
        return base.compactMap { group in
            let kept = group.filter { section in
                section.title.lowercased().contains(needle)
                    || section.keywords.contains { $0.contains(needle) }
            }
            return kept.isEmpty ? nil : kept
        }
    }
}

// MARK: - Row

private struct ServerSettingsSidebarRow: View {
    var section: ServerSettingsSection
    var isSelected: Bool
    var hasKeyboardFocus: Bool
    var pill: Namespace.ID
    var select: () -> Void

    @State private var isHovering = false
    @Environment(\.motion) private var motion

    var body: some View {
        Button(action: select) {
            HStack(spacing: SettingsMetrics.sidebarIconGap) {
                SettingsIconTile(
                    symbolName: section.symbolName,
                    tint: section.tint,
                    side: SettingsMetrics.sidebarIconSide,
                    radius: SettingsMetrics.sidebarIconRadius
                )
                Text(section.title)
                    .font(.system(.subheadline))
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, SettingsMetrics.sidebarRowLeading)
            .padding(.trailing, Spacing.tight)
            .frame(height: SettingsMetrics.sidebarRowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isSelected {
                    RoundedRectangle(
                        cornerRadius: SettingsMetrics.sidebarRowRadius,
                        style: .continuous
                    )
                    .fill(hasKeyboardFocus ? SettingsSurface.rowFocused : SettingsSurface.rowSelected)
                    .matchedGeometryEffect(id: "selection", in: pill)
                } else if isHovering {
                    RoundedRectangle(
                        cornerRadius: SettingsMetrics.sidebarRowRadius,
                        style: .continuous
                    )
                    .fill(SettingsSurface.rowHover)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(motion.hover) { isHovering = hovering }
        }
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

// MARK: - Search

private struct ServerSettingsSearchField: View {
    @Binding var query: String
    var isFocused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: Spacing.tight) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Ink.tertiary)
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .font(.system(.subheadline))
                .foregroundStyle(Ink.primary)
                .focused(isFocused)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Ink.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, Spacing.base)
        .frame(height: SettingsMetrics.searchFieldHeight)
        .background(
            SettingsSurface.searchField,
            in: .settingsRect(SettingsMetrics.sidebarRowRadius)
        )
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
