import Foundation
import MetricKit
import OSLog

/// What macOS itself noticed about this app: a hang, a crash, runaway CPU, a
/// burst of disk writes.
///
/// **The reports a tester cannot give.** Somebody who says "it froze for a
/// second while I was scrolling" has told the truth and nothing that can be
/// acted on; the system saw the same freeze and recorded which functions the
/// main thread was in. MetricKit hands those records to the app — usually on
/// the next launch, at most a day late — and this files each one, as the JSON
/// it arrives in, in the folder Settings › Diagnostics › Reveal Logs opens. So
/// "send me your logs" includes them, and nothing leaves the Mac on its own.
///
/// The stacks in them are addresses, as a stripped build's always are;
/// `scripts/symbolicate.sh` documents how they are read against a build's dSYM.
final class SystemDiagnostics: NSObject, MXMetricManagerSubscriber {
    static let shared = SystemDiagnostics()

    private nonisolated static let log = Logger(subsystem: "dev.wingcord.Wingcord", category: "Diagnostics")
    /// How many are kept. Each is a few kilobytes; the newest are the ones
    /// anybody will be asked for.
    private nonisolated static let kept = 20

    private var isStarted = false

    /// Asks to be handed the system's reports. Idempotent.
    func start() {
        // **A process with no bundle has none to be handed**, and asking is not
        // safe everywhere one is missing — `INVARIANTS.md` §6 has the same
        // guard for notifications. A test and `swift run` are that process.
        guard !isStarted, Bundle.main.bundleIdentifier != nil else { return }
        isStarted = true
        MXMetricManager.shared.add(self)
    }

    /// Called by the system on a queue of its own.
    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let directory = CrashReporter.reportDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (index, payload) in payloads.enumerated() {
            let stamp = Int(payload.timeStampEnd.timeIntervalSince1970)
            let url = directory.appending(path: "system-\(stamp)-\(index).json")
            do {
                try payload.jsonRepresentation().write(to: url, options: .atomic)
            } catch {
                Self.log.error("could not file a system report: \(error.localizedDescription, privacy: .public)")
            }
        }
        Self.prune(in: directory)
    }

    /// Keeps the newest few.
    private nonisolated static func prune(in directory: URL) {
        let reports = ((try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("system-") && $0.pathExtension == "json" }
            // The name opens with the time it covers, so the names sort by age.
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for report in reports.dropFirst(kept) {
            try? FileManager.default.removeItem(at: report)
        }
    }
}
