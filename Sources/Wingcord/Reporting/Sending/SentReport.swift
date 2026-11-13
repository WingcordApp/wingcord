import Foundation

/// A report this Mac sent, as much as its tester needs to follow it
/// (docs/BUG-REPORTING.md D28) — kept on this Mac only.
nonisolated struct SentReport: Codable, Identifiable, Hashable, Sendable {
    enum Status: String, Codable, Hashable, Sendable {
        case received
        case solved
        case published
        case fixed
        case wontfix
        /// The service no longer has it: 90 days passed and nobody published it.
        case expired

        var title: String {
            switch self {
            case .received: "Received"
            case .solved: "Solved"
            case .published: "Published"
            case .fixed: "Fixed"
            case .wontfix: "Won't Fix"
            case .expired: "Expired"
            }
        }

        /// An idea is added rather than fixed, and not planned rather than
        /// not fixed — the words its forum post wears (docs/BUG-REPORTING.md D27).
        func title(for kind: ReportKind) -> String {
            guard kind == .idea else { return title }
            switch self {
            case .fixed: return "Added"
            case .wontfix: return "Not Planned"
            default: return title
            }
        }
    }

    /// Where a published report can be followed (phase 7).
    struct Links: Codable, Hashable, Sendable {
        var issue: URL?
        var post: URL?
    }

    /// `WC-4F2K`. Not this value's identity: a crash counted into someone
    /// else's report shares their id.
    var reportID: String
    /// What the service handed back for this sender: it opens the report's
    /// status and nothing else.
    var key: String
    var kind: ReportKind
    /// The first line of what was written.
    var title: String
    var sentAt: Date
    /// Counted into a report another tester sent first.
    var wasRepeat: Bool
    /// Parts the service asked for and never got — the words went, the file
    /// did not.
    var missingParts: [String]
    var status: Status
    var links: Links
    var checkedAt: Date?

    var id: String { key }
}
