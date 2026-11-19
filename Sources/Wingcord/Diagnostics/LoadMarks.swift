import Foundation
import WingcordCore

/// How long a channel took to come in, written as one line per channel opened
/// (BETA2.md D4: measure before optimising).
///
/// **What "very slow at loading" is made of, in the log a report carries.**
/// The open, then the moments its parts land — the newest page of history, the
/// member list's first rows, the first faces — each as the time since the open.
/// One line, written once the parts are in or five seconds have passed, so a
/// part that never came says so ("roster —") rather than being left out.
@MainActor
final class LoadMarks {
    static let shared = LoadMarks()

    /// **The member list's three moments** (docs/BETA3.md §1.9): `roster` is
    /// the first update of any kind for the list, which can be a presence
    /// change carrying only the group counts — so it said 190 ms while the rows
    /// stayed placeholders. `listAsked` is the subscription leaving the socket,
    /// `listSync` Discord's page of rows arriving, `listFull` the first rows
    /// all drawable (sent, and their people's records held).
    enum Part: String, CaseIterable, Sendable {
        case history, painted, roster, faces
        case listAsked = "list asked"
        case listSync = "list page"
        case listFull = "list full"
    }

    private var channelID: ChannelID?
    private var openedAt: ContinuousClock.Instant?
    private var isCached = false
    private var marks: [Part: Duration] = [:]
    /// Short facts about the open that are not times ("list kept").
    private var notes: [String] = []
    private var deadline: Task<Void, Never>?

    /// How long the line waits for the parts that have not come. Long enough
    /// that a list taking several seconds still gets its number.
    private static let patience: Duration = .seconds(20)

    func opened(_ channelID: ChannelID, isCached: Bool) {
        if self.channelID != nil { flush() }
        self.channelID = channelID
        self.isCached = isCached
        openedAt = .now
        marks = [:]
        notes = []
        deadline?.cancel()
        deadline = Task { [weak self] in
            try? await Task.sleep(for: Self.patience)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Records the first time `part` landed for the channel being opened.
    func mark(_ part: Part, in channelID: ChannelID) {
        guard channelID == self.channelID, let openedAt, marks[part] == nil else { return }
        marks[part] = .now - openedAt
        // A channel whose history was already here waits for no page.
        let wanted = Part.allCases.filter { !(isCached && $0 == .history) }
        if wanted.allSatisfy({ marks[$0] != nil }) { flush() }
    }

    /// Adds a fact to the line of the channel being opened, once.
    func note(_ text: String, in channelID: ChannelID) {
        guard channelID == self.channelID, !notes.contains(text) else { return }
        notes.append(text)
    }

    private func flush() {
        deadline?.cancel()
        deadline = nil
        guard let channelID else { return }
        self.channelID = nil
        let parts = Part.allCases.map { part -> String in
            let value = marks[part].map(LogMessage.describe) ?? "—"
            return "\(part.rawValue) \(value)"
        }
        let facts = notes.isEmpty ? "" : " [\(notes.joined(separator: ", "))]"
        Log.info(
            .perf,
            "channel \(channelID) came in\(public: isCached ? " (cached)" : ""): \(public: parts.joined(separator: ", "))\(public: facts)"
        )
    }
}
