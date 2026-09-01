import AppKit
import Darwin
import Foundation
import OSLog
import QuartzCore

/// What the app is costing, right now.
///
/// A value, so the inspector and the settings pane read the same numbers and a
/// snapshot can be logged or compared without holding the monitor.
struct PerformanceSnapshot: Equatable, Sendable {
    /// `phys_footprint`, in bytes.
    ///
    /// **Not `resident_size`.** Resident size counts pages shared with other
    /// processes and pages the kernel has not yet reclaimed, so it wanders by
    /// tens of megabytes for reasons that have nothing to do with this app.
    /// `phys_footprint` is what Activity Monitor shows and what a jetsam
    /// decision is made on — it is the number that means something.
    var footprint: UInt64 = 0
    /// The last frame's duration in milliseconds, and the worst of the recent
    /// window.
    var lastFrameMilliseconds: Double = 0
    var worstFrameMilliseconds: Double = 0
    /// Frames in the recent window that missed the display's cadence.
    var slowFrames: Int = 0
    var displayHertz: Double = 60
    var residentChannels: Int = 0
    var residentMessages: Int = 0
    var imageBudgetBytes: Int = 0
    /// Whether a scroll is holding the work gate.
    var isScrolling = false

    static let empty = PerformanceSnapshot()

    var footprintDescription: String {
        ByteCountFormatStyle(style: .memory).format(Int64(footprint))
    }

    var imageBudgetDescription: String {
        ByteCountFormatStyle(style: .memory).format(Int64(imageBudgetBytes))
    }
}

/// Samples the app's cost.
///
/// **It costs nothing while nobody is looking.** The display link is installed
/// only when the inspector is shown or a benchmark is running; a monitor that
/// ticks at the refresh rate for the life of the process is itself a
/// battery cost, and one that measures a frame time it then spends is measuring
/// itself.
@MainActor
final class PerformanceMonitor {
    static let shared = PerformanceMonitor()

    private static let log = Logger(
        subsystem: "dev.wingcord.Wingcord",
        category: "Performance"
    )

    /// A ring of recent frame durations, in seconds.
    ///
    /// Fixed size and overwritten in place: a growing array of frame times is a
    /// memory leak that only shows up after an hour, in the tool that exists to
    /// find memory leaks.
    private var frameDurations = [Double](repeating: 0, count: 300)
    private var frameCursor = 0
    private var frameCount = 0
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var displayHertz: Double = 60

    /// Set by the app so the snapshot can report what the store is holding.
    weak var model: AppModel?

    private init() {}

    // MARK: Sampling

    /// Starts frame sampling. Idempotent.
    func startSampling(in view: NSView) {
        guard displayLink == nil else { return }
        let link = view.displayLink(target: self, selector: #selector(frameTick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stopSampling() {
        displayLink?.invalidate()
        displayLink = nil
        lastTimestamp = 0
    }

    @objc private func frameTick(_ link: CADisplayLink) {
        let now = link.timestamp
        defer { lastTimestamp = now }
        guard lastTimestamp > 0 else { return }
        let duration = now - lastTimestamp
        // The display's own cadence, read from the link rather than assumed:
        // a ProMotion Mac at 120 Hz has an 8.3 ms budget and a 60 Hz external
        // display has 16.7, and calling the first "slow" against the second's
        // budget hides every hitch on the machine most likely to have them.
        let interval = link.targetTimestamp - link.timestamp
        if interval > 0 { displayHertz = 1 / interval }

        frameDurations[frameCursor] = duration
        frameCursor = (frameCursor + 1) % frameDurations.count
        frameCount = min(frameCount + 1, frameDurations.count)
    }

    // MARK: Reading

    func snapshot() -> PerformanceSnapshot {
        var snapshot = PerformanceSnapshot()
        snapshot.footprint = Self.physicalFootprint()
        snapshot.displayHertz = displayHertz
        snapshot.isScrolling = ScrollWorkGate.isActive
        snapshot.imageBudgetBytes = ImageStore.Budget.total

        if frameCount > 0 {
            // A frame counts as slow at 1.5x the display's own interval: exactly
            // one interval is the budget and floating-point jitter around it
            // would report a permanent stream of false positives.
            let budget = 1 / displayHertz * 1.5
            var worst: Double = 0
            var slow = 0
            for index in 0..<frameCount {
                let duration = frameDurations[index]
                if duration > worst { worst = duration }
                if duration > budget { slow += 1 }
            }
            let previous = (frameCursor - 1 + frameDurations.count) % frameDurations.count
            snapshot.lastFrameMilliseconds = frameDurations[previous] * 1000
            snapshot.worstFrameMilliseconds = worst * 1000
            snapshot.slowFrames = slow
        }

        if let model {
            snapshot.residentChannels = model.residentChannelCount
            snapshot.residentMessages = model.residentMessageCount
        }
        return snapshot
    }

    /// The process's physical footprint.
    ///
    /// `nonisolated` so a crash handler or a background task can read it.
    nonisolated static func physicalFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}

extension AppModel {
    var residentChannelCount: Int {
        messageBoxes.count(where: { !$0.value.messages.isEmpty })
    }

    var residentMessageCount: Int {
        messageBoxes.values.reduce(0) { $0 + $1.messages.count }
    }
}

/// Responds to real memory pressure.
///
/// **A real signal, not a guess.** Guessing a smaller steady-state budget costs
/// every user a worse experience to serve the pressure case; responding to
/// `DispatchSourceMemoryPressure` costs nothing until the system actually says
/// it needs the memory back.
///
/// It also sheds on the window going out of sight for long enough, because
/// waiting only for a pressure event is waiting for something that may never
/// arrive on a Mac with plenty of memory — and until then the caches hold
/// pictures nobody can see.
@MainActor
final class MemoryPressureWatcher {
    static let shared = MemoryPressureWatcher()

    private var source: DispatchSourceMemoryPressure?
    private var hiddenShedTask: Task<Void, Never>?
    weak var model: AppModel?

    private init() {}

    func start() {
        guard source == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let event = source.data
                if event.contains(.critical) {
                    self.model?.relieveMemoryPressure()
                } else {
                    ImageStore.shared.shedLargeImages()
                }
            }
        }
        // A `DispatchSource` that was created and never resumed must never be
        // released — libdispatch traps on it. Resuming here, before it is
        // stored, means there is no window in which an unresumed source is
        // reachable.
        source.resume()
        self.source = source
    }

    /// Called when the window goes out of sight.
    func windowDidHide() {
        hiddenShedTask?.cancel()
        hiddenShedTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            await MainActor.run { _ = self }
            ImageStore.shared.shedLargeImages()
        }
    }

    func windowDidShow() {
        hiddenShedTask?.cancel()
        hiddenShedTask = nil
    }
}
