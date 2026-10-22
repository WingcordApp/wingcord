import Foundation
import WingcordCore

/// A shared theme the reader kept — Settings › Appearance › Saved Themes.
nonisolated struct SavedTheme: Hashable, Sendable, Codable, Identifiable {
    var id = UUID()
    var theme: SharedClientTheme
    /// Who shared it, as their name read then — "Created by" under its tile.
    var creatorName: String?
    var savedAt = Date()
}
