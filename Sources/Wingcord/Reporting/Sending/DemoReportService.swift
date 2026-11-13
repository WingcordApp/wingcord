import Foundation

/// The demo's reports service: answers as the real one does, a moment
/// later, and sends nothing anywhere — the demo must never put a report in
/// the developer's inbox.
nonisolated struct DemoReportService: ReportService {
    func send(_ upload: ReportUpload) async throws(ReportSendError) -> SentReport {
        try? await Task.sleep(for: .milliseconds(900))
        return SentReport(
            reportID: "WC-D3M0",
            key: UUID().uuidString,
            kind: upload.submission.kind,
            title: upload.title,
            sentAt: .now,
            wasRepeat: false,
            missingParts: [],
            status: .received,
            links: .init(),
            checkedAt: nil
        )
    }

    func status(of report: SentReport) async throws(ReportSendError) -> ReportStatusAnswer {
        try? await Task.sleep(for: .milliseconds(400))
        return ReportStatusAnswer(status: report.status, links: report.links)
    }
}
