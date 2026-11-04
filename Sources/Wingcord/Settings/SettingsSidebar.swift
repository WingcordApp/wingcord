import SwiftUI

// MARK: - The sidebar
//
// The system's sidebar list: its selection highlight, its row metrics (which
// follow the reader's sidebar icon size in General settings), its arrow keys
// and type-select, and its search field. Twenty rows in five groups, separated
// by space alone, each with the coloured tile the system's own Settings uses.

struct SettingsSidebar: View {
    @Binding var selection: SettingsSection?
    @Binding var query: String
    /// Opens a setting a search found — its pane, scrolled to it and lit.
    var show: (SettingsSearchEntry) -> Void = { _ in }

    var body: some View {
        List(selection: $selection) {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                ForEach(SettingsSection.groups, id: \.self) { group in
                    Section {
                        ForEach(group) { section in
                            row(section)
                        }
                    }
                }
            } else {
                // **Settings, under the pane they live on** (D10c), as System
                // Settings lists them: the pane's own row, then each setting
                // that matched, a step in.
                let results = SettingsSearch.results(for: query)
                if results.isEmpty {
                    Text("No settings match “\(query)”.")
                        .font(.system(.callout))
                        .foregroundStyle(Ink.secondary)
                        .selectionDisabled()
                }
                ForEach(results, id: \.section) { result in
                    Section {
                        row(result.section)
                        ForEach(result.settings) { entry in
                            SettingsSearchResultRow(entry: entry) { show(entry) }
                                .selectionDisabled()
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $query, placement: .sidebar, prompt: "Search settings")
        .accessibilityLabel("Settings sections")
    }

    private func row(_ section: SettingsSection) -> some View {
        Label {
            Text(section.title)
        } icon: {
            SettingsIconTile(
                symbolName: section.symbolName,
                tint: section.tint,
                side: SettingsMetrics.sidebarIconSide,
                radius: SettingsMetrics.sidebarIconRadius
            )
        }
        .tag(section)
    }
}

/// One setting a search found: its name, and the line that explains it.
private struct SettingsSearchResultRow: View {
    var entry: SettingsSearchEntry
    var open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title)
                    .font(.system(.callout, weight: .medium))
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                if !entry.help.isEmpty {
                    Text(entry.help)
                        .font(.system(.caption))
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.leading, SettingsMetrics.sidebarIconSide + Spacing.base)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(entry.title), in \(entry.section.title)"))
        .accessibilityHint(Text(entry.help))
    }
}
