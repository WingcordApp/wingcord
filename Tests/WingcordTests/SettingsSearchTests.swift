import Foundation
import Testing
@testable import Wingcord

/// Settings search: the index of every setting, and what a word finds.
@Suite("Settings search")
struct SettingsSearchTests {

    /// The sources the index is read off — `scripts/settings-index.py`'s list.
    private static let sources = [
        "Settings/SettingsPanes.swift", "Settings/SettingsPanes+Games.swift", "Settings/VoiceVideoPane.swift",
        "Settings/StreamerModePane.swift", "Settings/ConnectedAppsPane.swift", "Settings/ExperimentsPane.swift",
        "Settings/MessagingPermissionsPane.swift", "Settings/NowPlayingSettingsGroup.swift",
        "Settings/GameEventsSettingsGroup.swift", "Settings/RegisteredGamesGroup.swift",
        "Settings/BroadcastPreviewGroup.swift", "Settings/ConnectedRPCAppsGroup.swift",
        "Settings/FocusSettingsGroup.swift", "Settings/FocusCustomStatusRow.swift", "Settings/AccountInfoCard.swift",
        "Settings/AccountStandingCard.swift", "Settings/Plumage.swift", "Settings/ThemeGallery.swift",
        "Wallpaper/WallpaperPicker.swift",
    ]

    private static func sourceText() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Wingcord")
        let text = try sources.map { try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8) }
            .joined(separator: "\n")
        // The source writes some characters as escapes — `\u{2019}` — and the
        // index holds the characters themselves.
        let escape = try Regex(#"\\u\{([0-9A-Fa-f]+)\}"#)
        return text.replacing(escape) { match in
            let hex = match.output[1].substring.map(String.init) ?? ""
            return UInt32(hex, radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? ""
        }
    }

    @Test("Every switch in the panes is in the index, and every indexed row is still in a pane")
    func indexInStep() throws {
        let text = try Self.sourceText()
        let indexed = Set(SettingsSearch.entries.map(\.title))
        // Every toggle and slider, by its title — the rows a reader searches for most.
        let pattern = try Regex(#"(?:SettingsToggle|SettingsSliderRow)\(\s*title:\s*"([^"\\]+)""#)
        var missing: [String] = []
        for match in text.matches(of: pattern) {
            guard let title = match.output[1].substring.map(String.init) else { continue }
            if !indexed.contains(title) { missing.append(title) }
        }
        #expect(missing.isEmpty, "rows the search cannot find — run scripts/settings-index.py: \(missing)")
        let gone = SettingsSearch.entries.filter { !text.contains("\"\($0.title)") }.map(\.title)
        #expect(gone.isEmpty, "indexed rows no pane draws any more: \(gone)")
    }

    @Test("A word finds the setting, under its pane")
    func findsSettings() throws {
        let vivid = SettingsSearch.results(for: "vivid")
        #expect(vivid.first?.section == .appearance)
        #expect(vivid.first?.settings.first?.title == "Vividness")

        let nitro = try #require(SettingsSearch.results(for: "fake nitro").first { $0.section == .extras })
        #expect(nitro.settings.contains { $0.title == "Fake Nitro" })

        // Case and accents fold.
        #expect(SettingsSearch.results(for: "COLOUR").contains { $0.settings.contains { $0.title == "Colour strength" } })
        // A shortcut, by its command.
        #expect(SettingsSearch.results(for: "mute").contains { $0.section == .shortcuts && !$0.settings.isEmpty })
        // A pane found by its name alone still shows.
        #expect(SettingsSearch.results(for: "clips").contains { $0.section == .clips })
        #expect(SettingsSearch.results(for: "   ").isEmpty)
    }

    @Test("A title's start outranks a word inside its description")
    func ranking() {
        let entry = SettingsSearchEntry(.general, "Developer mode", "Adds Copy Message ID")
        #expect(SettingsSearch.score(entry, needle: "dev") > SettingsSearch.score(entry, needle: "copy"))
        #expect(SettingsSearch.score(entry, needle: "mode") == 3)
        #expect(SettingsSearch.score(entry, needle: "zz") == 0)
    }

    @Test("A page remembered by its old name opens where it lives now")
    func legacyNames() {
        #expect(SettingsSection(stored: "media") == .chat)
        #expect(SettingsSection(stored: "messagingPermissions") == .privacySafety)
        #expect(SettingsSection(stored: "storage") == .performance)
        #expect(SettingsSection(stored: "connectedApps") == .connections)
        #expect(SettingsSection(stored: "appearance") == .appearance)
        #expect(SettingsSection(stored: "nonsense") == nil)
    }
}
