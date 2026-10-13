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

    var body: some View {
        List(selection: $selection) {
            ForEach(visibleGroups, id: \.self) { group in
                Section {
                    ForEach(group) { section in
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
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $query, placement: .sidebar, prompt: "Search")
        .accessibilityLabel("Settings sections")
    }

    /// The groups, with rows the search excludes removed and empty groups
    /// dropped — so a search never leaves a gap where a group used to be.
    private var visibleGroups: [[SettingsSection]] {
        // `isEmpty` before `trimmingCharacters`: the trim ALLOCATES, and the
        // empty query is not the rare case — it is every selection change.
        guard !query.isEmpty else { return SettingsSection.groups }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return SettingsSection.groups }
        let needle = trimmed.lowercased()
        return SettingsSection.groups.compactMap { group in
            let kept = group.filter {
                $0.title.lowercased().contains(needle) || $0.keywords.contains(needle)
            }
            return kept.isEmpty ? nil : kept
        }
    }
}
