import Foundation
import WingcordCore

/// A Server Hub being edited: Discord's `GuildSpaceEditorStore` draft.
///
/// **Nothing reaches Discord until Save.** Every change — a move, a new widget,
/// new words, a new banner — is made here, and Save sends the hub whole, which
/// is also how Cancel can put everything back by doing nothing.
struct ServerHubDraft: Hashable, Sendable {
    var guildID: GuildID
    /// The widgets as the edit began, for "anything changed?".
    var original: [GuildSpaceWidget]
    var widgets: [GuildSpaceWidget]
    var banner: Banner = .unchanged
    var saveState: SaveState = .idle
    /// A hub Discord doesn't have yet: the save creates it.
    var isNewHub: Bool

    enum Banner: Hashable, Sendable {
        case unchanged
        /// A picture picked from disk: the data URL a save sends, and the bytes
        /// the page shows meanwhile.
        case replaced(dataURL: String, preview: Data)
        case removed
    }

    enum SaveState: Hashable, Sendable {
        case idle
        case saving
        case failed(String)
    }

    init(guildID: GuildID, widgets: [GuildSpaceWidget], isNewHub: Bool) {
        self.guildID = guildID
        let normalized = GuildSpaceLayout.normalized(widgets)
        original = normalized
        self.widgets = normalized
        self.isNewHub = isNewHub
    }

    var hasChanges: Bool { isNewHub || widgets != original || banner != .unchanged }

    var isSaving: Bool { saveState == .saving }

    /// A new widget's id — Discord's `draft:` scheme, unique for the session.
    static func draftID() -> String {
        GuildSpaceWidget.draftPrefix + UUID().uuidString
    }
}
