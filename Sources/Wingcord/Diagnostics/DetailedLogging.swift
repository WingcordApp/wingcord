import Foundation
import Observation
import WingcordCore

/// "Detailed logging for 10 minutes" (docs/BUG-REPORTING.md D23): every step
/// of the connection, the calls and the screen share, for long enough to make
/// a problem happen again — and then off, by itself.
///
/// **For when a tester is asked to reproduce something.** The always-on log
/// keeps the lifecycle and the faults; this adds the protocol-level lines —
/// a line per gateway frame, the voice handshake's every message — which are
/// too many to keep for ever and exactly what a hard bug needs.
///
/// **The end time is stored**, so a window that a relaunch interrupts carries
/// on to its end: a tester reproducing a problem at launch has to quit and
/// reopen inside it. The clock is the wall clock — ten minutes is ten minutes
/// whether or not the Mac slept through some of them.
@Observable
@MainActor
final class DetailedLogging {
    static let shared = DetailedLogging()

    static let duration: Duration = .seconds(10 * 60)
    private static let endsAtKey = "diagnostics.detailedLoggingEndsAt"

    /// When it turns itself off, while it is on.
    private(set) var endsAt: Date?

    @ObservationIgnored private var timer: Task<Void, Never>?

    var isOn: Bool { endsAt != nil }

    /// `isOn` for a checkbox or a switch to write through.
    var isOnBinding: Bool {
        get { endsAt != nil }
        set { setOn(newValue) }
    }

    /// Picks up a window a relaunch interrupted. Call once, at launch.
    func restore() {
        guard let stored = UserDefaults.standard.object(forKey: Self.endsAtKey) as? Date else { return }
        if stored > .now {
            begin(until: stored, resuming: true)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.endsAtKey)
        }
    }

    func setOn(_ isOn: Bool) {
        if isOn { start() } else { stop() }
    }

    func start() {
        let seconds = Double(Self.duration.components.seconds)
        begin(until: Date.now.addingTimeInterval(seconds), resuming: false)
    }

    func stop() {
        guard endsAt != nil else { return }
        timer?.cancel()
        timer = nil
        endsAt = nil
        UserDefaults.standard.removeObject(forKey: Self.endsAtKey)
        // The developer's own switch outlasts this one.
        Log.setDetailed(AppLog.isTracingEverything)
        Log.info(.app, "detailed logging off")
    }

    /// What is left, as a person reads it: `9:41`.
    func remaining(at date: Date) -> String {
        guard let endsAt else { return "" }
        let seconds = max(0, Int(endsAt.timeIntervalSince(date).rounded(.up)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func begin(until date: Date, resuming: Bool) {
        endsAt = date
        UserDefaults.standard.set(date, forKey: Self.endsAtKey)
        Log.setDetailed(true)
        let minutes = max(1, Int((date.timeIntervalSinceNow / 60).rounded(.up)))
        Log.info(.app, resuming
            ? "detailed logging carried over a relaunch, \(minutes) minutes left"
            : "detailed logging on for \(minutes) minutes")
        timer?.cancel()
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }
}
