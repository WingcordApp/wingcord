import CoreFoundation
import Darwin
import Foundation
import Synchronization
import WingcordCore

/// Soft crashes: the main thread stalling or hanging (docs/BUG-REPORTING.md
/// D19).
///
/// **It watches the main run loop's own heartbeat rather than pinging it.** A
/// ping a few times a second would wake an idle app a few times a second for
/// as long as it is open. Instead an observer on the main run loop stamps the
/// time at every turn — before its timers, before its sources, as it wakes —
/// and says when it goes to sleep. A background thread looks at the stamp:
///
/// - **asleep** — the app is idle; the watcher parks until the run loop wakes,
///   so an idle app costs nothing at all;
/// - **awake, and the stamp 250 ms old** — one turn of the run loop has been
///   running that long: a stall. The main thread's stack is sampled there;
/// - **2 seconds old** — a hang. Sampled again, and a marker is written to
///   disk, so that if the person gives up and force-quits, the next launch
///   finds the marker and knows how the last run ended.
///
/// When the stamp moves again the stall is over, and its length is exact: the
/// first stamp after it, minus the last one before.
///
/// **The watcher's own lateness voids a reading.** A debugger stopping the
/// process, App Nap or a starved machine stops this thread too, and when it
/// wakes the main thread looks to have stood still for exactly as long. A
/// check that comes more than 250 ms later than it asked to is thrown away.
/// The clock is `CLOCK_UPTIME_RAW`, which stops while the Mac sleeps.
nonisolated final class MainThreadWatchdog: @unchecked Sendable {
    static let shared = MainThreadWatchdog()

    static let stallThreshold: UInt64 = 250_000_000
    static let hangThreshold: UInt64 = 2_000_000_000
    private static let checkInterval: UInt64 = 100_000_000
    /// At most one stall line per this long; the rest are counted into it.
    private static let stallLineSpacing: UInt64 = 5_000_000_000

    /// The run loop's last turn, in uptime nanoseconds.
    private let lastActivity = Atomic<UInt64>(0)
    private let isWaiting = Atomic<Bool>(true)
    /// Set while the watcher is parked, so only then does a waking run loop
    /// spend a signal on it.
    private let isParked = Atomic<Bool>(false)
    private let wake = DispatchSemaphore(value: 0)
    private var observer: CFRunLoopObserver?
    private var thread: Thread?

    /// Where a hang that is still going on is written down.
    static var hangMarkerURL: URL {
        CrashReporter.reportDirectory.appending(path: "hang-in-progress.txt")
    }

    /// Starts watching. Call once, on the main thread, after the log is open.
    @MainActor
    func start() {
        guard thread == nil else { return }
        lastActivity.store(Self.now(), ordering: .relaxed)
        let activities: CFRunLoopActivity = [.entry, .beforeTimers, .beforeSources, .beforeWaiting, .afterWaiting, .exit]
        let observer = CFRunLoopObserverCreateWithHandler(nil, activities.rawValue, true, 0) { [unowned self] _, activity in
            self.lastActivity.store(Self.now(), ordering: .relaxed)
            if activity == .beforeWaiting {
                self.isWaiting.store(true, ordering: .relaxed)
            } else if self.isWaiting.load(ordering: .relaxed) {
                self.isWaiting.store(false, ordering: .relaxed)
                if self.isParked.load(ordering: .relaxed) { self.wake.signal() }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer

        // On the main thread, so this is the main thread's own port.
        let mainPort = pthread_mach_thread_np(pthread_self())
        let thread = Thread { [unowned self] in self.watch(mainThread: mainPort) }
        thread.name = "Wingcord watchdog"
        thread.qualityOfService = .userInteractive
        thread.stackSize = 256 * 1024
        self.thread = thread
        thread.start()
    }

    // MARK: Watching

    private func watch(mainThread: thread_act_t) {
        let frames = UnsafeMutablePointer<UInt>.allocate(capacity: StackSampler.capacity)
        defer { frames.deallocate() }
        var lastCheck = Self.now()
        var stall: Stall?
        var lastStallLine: UInt64 = 0
        var unreportedStalls = 0

        while true {
            if isWaiting.load(ordering: .relaxed), stall == nil {
                isParked.store(true, ordering: .relaxed)
                // Checked again after parking, so a wake between the two
                // loads is not missed.
                if isWaiting.load(ordering: .relaxed) { wake.wait() }
                isParked.store(false, ordering: .relaxed)
                lastCheck = Self.now()
                continue
            }
            usleep(useconds_t(Self.checkInterval / 1_000))
            let now = Self.now()
            let overslept = now - lastCheck > Self.checkInterval + 250_000_000
            lastCheck = now
            let activity = lastActivity.load(ordering: .relaxed)

            if var current = stall {
                if activity != current.began {
                    // Moving again: the stall is over, and this is its length.
                    current.ended = activity
                    if !current.isVoid {
                        report(current, lastLine: &lastStallLine, unreported: &unreportedStalls)
                    }
                    stall = nil
                    continue
                }
                if overslept { current.isVoid = true }
                let waited = now &- current.began
                if !current.isVoid, waited >= Self.hangThreshold, current.hangSample == nil {
                    let depth = StackSampler.sample(mainThread, into: frames)
                    current.hangSample = Array(UnsafeBufferPointer(start: frames, count: depth))
                    beginHang(current, waited: waited)
                }
                stall = current
                continue
            }

            guard !isWaiting.load(ordering: .relaxed), !overslept else { continue }
            let waited = now &- activity
            if waited >= Self.stallThreshold {
                var current = Stall(began: activity)
                let depth = StackSampler.sample(mainThread, into: frames)
                current.stallSample = Array(UnsafeBufferPointer(start: frames, count: depth))
                stall = current
            }
        }
    }

    private struct Stall {
        var began: UInt64
        var ended: UInt64 = 0
        var stallSample: [UInt] = []
        var hangSample: [UInt]?
        /// The watcher itself was held up, so the length means nothing.
        var isVoid = false

        var duration: UInt64 { ended &- began }
    }

    // MARK: Reporting

    private func report(_ stall: Stall, lastLine: inout UInt64, unreported: inout Int) {
        let duration = Duration.nanoseconds(Int64(stall.duration))
        if let hangSample = stall.hangSample {
            try? FileManager.default.removeItem(at: Self.hangMarkerURL)
            Log.fault(.perf, "the main thread hung for \(duration)")
            for line in StackSampler.describe(hangSample) { Log.fault(.perf, .raw("  " + line)) }
            return
        }
        let now = Self.now()
        guard now &- lastLine >= Self.stallLineSpacing else {
            unreported += 1
            return
        }
        lastLine = now
        let others = unreported > 0 ? " (and \(unreported) shorter since the last)" : ""
        unreported = 0
        // The few frames that say where: the top of the stack, folded onto
        // one line, so a run of stalls stays a run of lines.
        let top = StackSampler.describe(stall.stallSample).prefix(8).joined(separator: " ← ")
        Log.info(.perf, .raw("the main thread stalled for \(LogMessage.describe(duration))\(others) in: \(top)"))
    }

    /// Two seconds in: the line, the stack, and the marker on disk.
    private func beginHang(_ stall: Stall, waited: UInt64) {
        let lines = StackSampler.describe(stall.hangSample ?? [])
        Log.fault(.perf, "the main thread has not answered for \(Duration.nanoseconds(Int64(waited)))")
        var marker = "Wingcord's main thread stopped answering at "
            + ISO8601DateFormatter().string(from: Date()) + ".\n"
            + CrashReporter.mainImageLine
            + "\n--- main thread, two seconds in ---\n"
            + lines.joined(separator: "\n") + "\n"
        if !stall.stallSample.isEmpty {
            marker += "\n--- main thread, a quarter second in ---\n"
                + StackSampler.describe(stall.stallSample).joined(separator: "\n") + "\n"
        }
        try? marker.write(to: Self.hangMarkerURL, atomically: true, encoding: .utf8)
    }

    static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
}

// MARK: - The main thread's stack, from another thread

/// Walks a suspended thread's frame pointers.
///
/// **Nothing between the suspend and the resume may allocate or take a
/// lock**: the suspended thread may be holding `malloc`'s lock, or any other,
/// and waiting on it from here would hang the watcher inside the hang it is
/// recording. So the frames go into a buffer allocated beforehand, memory is
/// read with `vm_read_overwrite` — a system call that fails rather than
/// faulting on a bad address — and the names are looked up only after the
/// thread is running again.
nonisolated enum StackSampler {
    static let capacity = 64

    /// The return addresses, innermost first. Zero frames where the thread
    /// could not be read.
    static func sample(_ thread: thread_act_t, into buffer: UnsafeMutablePointer<UInt>) -> Int {
        #if arch(arm64)
        guard thread_suspend(thread) == KERN_SUCCESS else { return 0 }
        defer { thread_resume(thread) }
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size
        )
        let status = withUnsafeMutablePointer(to: &state) { pointer in
            pointer.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                thread_get_state(thread, thread_state_flavor_t(ARM_THREAD_STATE64), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return 0 }
        var depth = 0
        buffer[depth] = UInt(state.__pc) & addressMask
        depth += 1
        let link = UInt(state.__lr) & addressMask
        if link != 0 {
            buffer[depth] = link
            depth += 1
        }
        var frame = UInt(state.__fp)
        while depth < capacity, frame != 0, frame & 0x7 == 0 {
            var pair: (next: UInt, returnAddress: UInt) = (0, 0)
            var read: vm_size_t = 0
            let result = withUnsafeMutablePointer(to: &pair) { pointer in
                vm_read_overwrite(
                    mach_task_self_,
                    vm_address_t(frame),
                    vm_size_t(MemoryLayout<UInt>.size * 2),
                    vm_address_t(UInt(bitPattern: pointer)),
                    &read
                )
            }
            guard result == KERN_SUCCESS, read == vm_size_t(MemoryLayout<UInt>.size * 2) else { break }
            let address = pair.returnAddress & addressMask
            guard address != 0 else { break }
            // The link register is the first saved return address whenever the
            // innermost function is not a leaf; once is enough.
            if !(depth == 2 && address == buffer[1]) {
                buffer[depth] = address
                depth += 1
            }
            // A frame chain only goes up the stack. Anything else is a frame
            // pointer the code did not keep, and following it reads garbage.
            guard pair.next > frame else { break }
            frame = pair.next
        }
        return depth
        #else
        return 0
        #endif
    }

    /// User addresses on this hardware fit in 47 bits; the bits above are a
    /// pointer signature where there is one.
    private static let addressMask: UInt = (1 << 47) - 1

    /// `3 SwiftUI ViewGraph.updateOutputs + 112`, `7 Wingcord +0x1a2b3c`.
    ///
    /// **The app's own frames are offsets, never names**: a shipped build is
    /// stripped, and the nearest symbol it still exports would name the wrong
    /// function with total confidence. `scripts/symbolicate.sh` reads an
    /// offset against the build's dSYM. A system library's names are its own.
    static func describe(_ addresses: [UInt]) -> [String] {
        let mainImage = mainImageName
        return addresses.enumerated().map { index, address in
            var info = Dl_info()
            // A return address is the instruction after the call; one byte
            // back is inside the calling function, whichever it is.
            let lookup = index == 0 ? address : address &- 1
            guard dladdr(UnsafeRawPointer(bitPattern: lookup), &info) != 0, let base = info.dli_fbase else {
                return "\(index) ? 0x" + String(address, radix: 16)
            }
            let image = info.dli_fname.map { String(cString: $0) }
                .map { ($0 as NSString).lastPathComponent } ?? "?"
            let offset = address &- UInt(bitPattern: base)
            if image != mainImage, let symbol = info.dli_sname, let start = info.dli_saddr {
                return "\(index) \(image) \(String(cString: symbol)) + \(address &- UInt(bitPattern: start))"
            }
            return "\(index) \(image) +0x" + String(offset, radix: 16)
        }
    }

    private static let mainImageName: String = {
        guard let path = _dyld_get_image_name(0) else { return "Wingcord" }
        return (String(cString: path) as NSString).lastPathComponent
    }()
}
