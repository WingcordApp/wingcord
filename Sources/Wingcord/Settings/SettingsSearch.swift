import Foundation

/// One setting, as the search knows it.
struct SettingsSearchEntry: Hashable, Sendable, Identifiable {
    var section: SettingsSection
    var title: String
    var help: String

    init(_ section: SettingsSection, _ title: String, _ help: String = "") {
        self.section = section
        self.title = title
        self.help = help
    }

    var id: String { "\(section.rawValue)/\(title)" }
}

/// **Search finds settings, not only panes** (D10c; Alex, 2026-10-26:
/// "making the search bar search for settings too and not just settings
/// panes"). While a word is typed, the sidebar lists the settings that match
/// under their pane, the way System Settings does; choosing one opens the pane,
/// scrolls to the row and lights it.
enum SettingsSearch {

    /// The panes that match and, under each, the settings that do — best first.
    static func results(for query: String) -> [(section: SettingsSection, settings: [SettingsSearchEntry])] {
        let needle = normalised(query)
        guard !needle.isEmpty else { return [] }
        var bySection: [SettingsSection: [(entry: SettingsSearchEntry, score: Int)]] = [:]
        for entry in allEntries {
            let score = score(entry, needle: needle)
            guard score > 0 else { continue }
            bySection[entry.section, default: []].append((entry, score))
        }
        return SettingsSection.groups.flatMap(\.self).compactMap { section in
            let hits = (bySection[section] ?? []).sorted { $0.score > $1.score }.map(\.entry)
            let paneMatches = normalised(section.title).contains(needle) || section.keywords.contains(needle)
            guard !hits.isEmpty || paneMatches else { return nil }
            return (section, Array(hits.prefix(6)))
        }
    }

    /// The generated rows, and the shortcuts by their commands — the Shortcuts
    /// pane draws those from these same lists, so a search for "mute" finds
    /// the key that mutes.
    static let allEntries: [SettingsSearchEntry] = {
        var seen = Set(entries.map(\.id))
        let shortcuts = GlobalAction.allCases.map { SettingsSearchEntry(.shortcuts, $0.title, $0.help) }
            + AppShortcut.allCases.map { SettingsSearchEntry(.shortcuts, $0.title) }
        return entries + shortcuts.filter { seen.insert($0.id).inserted }
    }()

    /// Title first — its start most of all — then the words that explain it.
    static func score(_ entry: SettingsSearchEntry, needle: String) -> Int {
        let title = normalised(entry.title)
        if title.hasPrefix(needle) { return 4 }
        if title.split(separator: " ").contains(where: { $0.hasPrefix(needle) }) { return 3 }
        if title.contains(needle) { return 2 }
        if needle.count >= 3, normalised(entry.help).contains(needle) { return 1 }
        return 0
    }

    /// Case and accents folded, so "colour" finds "Colour" and "anonymise"
    /// finds "Anonymise".
    static func normalised(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespaces)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
