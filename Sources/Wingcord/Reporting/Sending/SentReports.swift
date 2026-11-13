import Foundation
import Observation
import WingcordCore

/// The reports this Mac sent, newest first — Your Reports
/// (docs/BUG-REPORTING.md D28).
///
/// **Kept on this Mac only**, beside the log, readable by its owner alone:
/// each entry's key opens that report's status and nothing else, but it is
/// still nobody else's to read.
@Observable
@MainActor
final class SentReports {
    static let shared = SentReports()

    /// Enough to follow a season of testing; the oldest go first.
    static let kept = 50

    private(set) var reports: [SentReport]
    private(set) var isRefreshing = false

    @ObservationIgnored private let url: URL

    init(url: URL = CrashReporter.reportDirectory.appending(path: "sent-reports.json")) {
        self.url = url
        reports = Self.load(from: url)
    }

    func add(_ report: SentReport) {
        reports.removeAll { $0.key == report.key }
        reports.insert(report, at: 0)
        if reports.count > Self.kept { reports.removeLast(reports.count - Self.kept) }
        save()
    }

    /// Asks the service about every report it may still have, all at once.
    func refresh(using service: any ReportService) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let asking = reports.filter { $0.status != .expired }
        let answers = await withTaskGroup(of: (String, ReportStatusAnswer?).self) { group in
            for report in asking {
                group.addTask { (report.key, try? await service.status(of: report)) }
            }
            var collected: [String: ReportStatusAnswer] = [:]
            for await (key, answer) in group {
                if let answer { collected[key] = answer }
            }
            return collected
        }
        guard !answers.isEmpty else { return }
        let now = Date.now
        for index in reports.indices {
            guard let answer = answers[reports[index].key] else { continue }
            reports[index].status = answer.status
            reports[index].links = answer.links
            reports[index].checkedAt = now
        }
        save()
    }

    // MARK: Disk

    private static func load(from url: URL) -> [SentReport] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([SentReport].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(reports)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path(percentEncoded: false))
        } catch {
            Log.info(.app, "the list of sent reports could not be saved: \(error)")
        }
    }
}
