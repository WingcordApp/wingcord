import Foundation

/// Where a report goes (docs/BUG-REPORTING.md §9): the reports service, or
/// the demo's stand-in, which sends nothing anywhere.
nonisolated protocol ReportService: Sendable {
    func send(_ upload: ReportUpload) async throws(ReportSendError) -> SentReport
    func status(of report: SentReport) async throws(ReportSendError) -> ReportStatusAnswer
}

/// One report on its way: the JSON, and the parts it announces.
nonisolated struct ReportUpload: Sendable {
    var submission: ReportSubmission
    /// The zip of the files "See What's Sent" lists, without the picture.
    var bundle: Data?
    var screenshot: Data?
    /// The first line of what was written, for the list of sent reports.
    var title: String
}

nonisolated struct ReportStatusAnswer: Equatable, Sendable {
    var status: SentReport.Status
    var links: SentReport.Links
}

/// Why a report did not go, as the sheet says it.
nonisolated enum ReportSendError: Error, Equatable, Sendable {
    /// No answer: offline, or the service out of reach.
    case offline
    /// Too many from this Mac in the last hour, or from everyone today.
    case tooMany
    /// The service turned it down; its code is for the log.
    case refused(code: String)
    case server(status: Int)
    /// An answer this version cannot read.
    case unreadable

    /// What happened and what to do. A bug can always be saved as a file; an
    /// idea stays in the sheet for later.
    func message(for kind: ReportKind) -> String {
        let fallback = kind == .bug
            ? "You can save it as a file instead."
            : "Your idea stays here, so you can try again later."
        switch self {
        case .offline:
            return "Wingcord couldn't reach its reports server. \(fallback)"
        case .tooMany:
            return "Several reports went from this Mac in a short time. Try again in a while. \(fallback)"
        case .refused:
            return "The reports server didn't accept this report. \(fallback)"
        case .server:
            return "The reports server had a problem. Try again in a moment. \(fallback)"
        case .unreadable:
            return "The reports server answered in a way this version doesn't understand. \(fallback)"
        }
    }

    var logWord: String {
        switch self {
        case .offline: "offline"
        case .tooMany: "too many"
        case .refused(let code): "refused (\(code))"
        case .server(let status): "server \(status)"
        case .unreadable: "unreadable answer"
        }
    }
}
