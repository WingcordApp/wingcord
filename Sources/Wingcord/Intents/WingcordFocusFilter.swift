import AppIntents
import WingcordCore

// MARK: - The Focus filter
//
// What System Settings › Focus › (a Focus) › Focus Filters › Add Filter offers
// as "Wingcord". Its parameters are drawn there as a form — the status as a
// popup, the custom status as a text field — above the system's own on/off
// switch for the filter.
//
// **The defaults mean "nothing asked".** The system calls `perform()` again as
// the Focus ends, with every parameter at its default (measured on a real
// Focus, docs/CLIPS-PRESENCE.md Phase 0.2), so "Don't change" and no text is
// the end of a Focus, not a choice anybody makes. `suggestedFocusFilters`
// offers "Wingcord's Focus status" instead — Apple's documented use: "useful
// when the suggested focus configurations are different from the configuration
// when the focus is turned off".

enum FocusStatusChoice: String, AppEnum {
    case unchanged
    case wingcord
    case online
    case idle
    case doNotDisturb
    case invisible

    nonisolated static let typeDisplayRepresentation: TypeDisplayRepresentation = "Status"
    nonisolated static let caseDisplayRepresentations: [FocusStatusChoice: DisplayRepresentation] = [
        .unchanged: "Don't change",
        .wingcord: "Wingcord's Focus status",
        .online: "Online",
        .idle: "Idle",
        .doNotDisturb: "Do Not Disturb",
        .invisible: "Invisible",
    ]
}

struct WingcordFocusFilter: SetFocusFilterIntent {
    nonisolated static let title: LocalizedStringResource = "Set Wingcord Status"
    nonisolated static let description: IntentDescription? = IntentDescription(
        "Changes your Discord status while this Focus is on, and puts it back when it ends."
    )

    @Parameter(title: "Status", default: .unchanged)
    var status: FocusStatusChoice

    @Parameter(title: "Custom Status")
    var customStatus: String?

    @Dependency private var focus: FocusSync

    nonisolated var displayRepresentation: DisplayRepresentation {
        let custom = customStatus?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title: LocalizedStringResource = switch status {
        case .unchanged: custom.isEmpty ? "Status unchanged" : "Custom status only"
        case .wingcord: "Wingcord's Focus status"
        case .online: "Online"
        case .idle: "Idle"
        case .doNotDisturb: "Do Not Disturb"
        case .invisible: "Invisible"
        }
        return custom.isEmpty
            ? DisplayRepresentation(title: title)
            : DisplayRepresentation(title: title, subtitle: "\(custom)")
    }

    nonisolated static func suggestedFocusFilters(for context: FocusFilterSuggestionContext) async -> [WingcordFocusFilter] {
        let suggestion = WingcordFocusFilter()
        suggestion.status = .wingcord
        return [suggestion]
    }

    nonisolated init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        focus.filterChanged(status, customStatusText: customStatus)
        return .result()
    }
}
