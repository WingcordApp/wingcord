import Darwin
import Foundation
import OSLog

/// Catches the ways this app can die and leaves something worth reading.
///
/// **The hard constraint is that a signal handler runs in a context where almost
/// nothing is legal.** It may be entered on any thread, at any instruction,
/// possibly while `malloc`'s own lock is held — so it may not allocate, may not
/// take a lock, may not call Foundation, and may not use `print`. Every one of
/// those is a hang or a second crash inside the crash, which is why a naïve
/// crash handler so often produces no file at all.
///
/// So the report is assembled in two halves:
///
///  - **Everything that needs allocation is prepared in advance**, while the app
///    is healthy: the file is opened, the header is written, and the breadcrumb
///    ring is a fixed C buffer that is only ever overwritten in place.
///  - **The handler itself only calls `write(2)`** on the already-open
///    descriptor, plus `backtrace` and `backtrace_symbols_fd`, which are
///    documented async-signal-safe.
///
/// The result is that a crash leaves a file naming the signal, the thread, the
/// stack, the memory footprint at the moment it died, and the last hundred
/// things the app was doing — which is the difference between a bug that takes
/// an afternoon and one that takes a week.
nonisolated enum CrashReporter {
    private static let log = Logger(subsystem: "dev.wingcord.Wingcord", category: "Crash")

    /// The open descriptor the handler writes to. Opened while healthy.
    nonisolated(unsafe) private static var reportDescriptor: Int32 = -1
    /// This run's report, which a clean exit removes.
    nonisolated(unsafe) private static var reportPath: String?
    nonisolated(unsafe) private static var isInstalled = false

    /// Where reports go.
    ///
    /// **The release app keeps the folder it always had; any other bundle id —
    /// the isolated demo copy, a probe — gets one of its own.** Launching sweeps
    /// empty reports, and a running app's own report is empty until it crashes,
    /// so a demo copy sharing the folder would delete the real app's live report
    /// (and the session log is truncated per launch, by whoever launches).
    static var reportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL.temporaryDirectory
        let identifier = Bundle.main.bundleIdentifier ?? releaseIdentifier
        let folder = identifier == releaseIdentifier ? "Wingcord" : identifier
        return base.appending(path: "\(folder)/Diagnostics", directoryHint: .isDirectory)
    }

    private static let releaseIdentifier = "dev.wingcord.Wingcord"

    /// Installs the handlers. Call once, early.
    static func install() {
        guard !isInstalled else { return }
        isInstalled = true

        try? FileManager.default.createDirectory(
            at: reportDirectory,
            withIntermediateDirectories: true
        )
        sweepEmptyReports()

        let path = reportDirectory
            .appending(path: "crash-\(Int(Date.now.timeIntervalSince1970)).txt")
            .path(percentEncoded: false)
        reportPath = path
        reportDescriptor = path.withCString {
            open($0, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        }
        guard reportDescriptor >= 0 else { return }

        Breadcrumbs.record("session started")

        // An uncaught Objective-C exception. This one CAN allocate — it is
        // called before the process is torn down, on a normal thread — so it
        // gets the readable treatment.
        NSSetUncaughtExceptionHandler { exception in
            CrashReporter.writeException(exception)
        }

        for signalNumber in [SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT, SIGTRAP] {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = { number in
                CrashReporter.handle(signal: number)
            }
            sigemptyset(&action.sa_mask)
            action.sa_flags = 0
            sigaction(signalNumber, &action, nil)
        }
    }

    /// Reports left behind by previous runs, newest first.
    static func pendingReports() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: reportDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        return contents
            .filter { $0.lastPathComponent.hasPrefix("crash-") }
            .sorted { left, right in
                let leftDate = (try? left.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let rightDate = (try? right.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return leftDate > rightDate
            }
    }

    /// Removes this run's empty report.
    ///
    /// The file is created at launch so the handler has somewhere to write
    /// *without allocating*; a clean exit leaves it empty, and an empty file
    /// would otherwise look like a crash on the next launch. It removes **its
    /// own** path: the newest report in the folder is not necessarily this
    /// run's.
    static func finishCleanly() {
        guard reportDescriptor >= 0 else { return }
        let size = lseek(reportDescriptor, 0, SEEK_CUR)
        close(reportDescriptor)
        reportDescriptor = -1
        // Nothing was ever written: no crash happened.
        guard size <= 0, let reportPath else { return }
        try? FileManager.default.removeItem(atPath: reportPath)
    }

    /// Removes the empty reports earlier runs left.
    ///
    /// **A run that is killed never exits cleanly**, so the file it opened in
    /// case it crashed stays behind with nothing in it — one per rebuild, per
    /// force quit, per stop from a debugger. Nothing was ever written to one,
    /// so nothing happened in it; a hundred and fifty had piled up.
    private static func sweepEmptyReports() {
        for report in pendingReports()
        where (try? report.resourceValues(forKeys: [.fileSizeKey]))?.fileSize == 0 {
            try? FileManager.default.removeItem(at: report)
        }
    }

    // MARK: The handler

    /// Runs in signal context. Everything it calls must be async-signal-safe.
    private static func handle(signal number: Int32) {
        let descriptor = reportDescriptor
        guard descriptor >= 0 else { _exit(number) }

        write(descriptor, "\n=== SIGNAL ", 12)
        writeInteger(Int(number), to: descriptor)
        write(descriptor, " ===\n", 5)

        write(descriptor, "footprint-bytes ", 16)
        writeInteger(Int(PerformanceMonitor.physicalFootprint()), to: descriptor)
        write(descriptor, "\n", 1)

        Breadcrumbs.dump(to: descriptor)

        write(descriptor, "\n--- backtrace ---\n", 19)
        var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 128)
        let depth = backtrace(&frames, Int32(frames.count))
        // `backtrace_symbols_fd` writes straight to the descriptor rather than
        // allocating an array of strings, which is precisely why it is the one
        // symbolication call legal here.
        backtrace_symbols_fd(&frames, depth, descriptor)

        fsync(descriptor)
        close(descriptor)
        reportDescriptor = -1

        // Restore the default handler and re-raise, so the crash still reaches
        // the system reporter with a real signal rather than being swallowed.
        signal(number, SIG_DFL)
        raise(number)
    }

    /// Writes an integer without allocating.
    private static func writeInteger(_ value: Int, to descriptor: Int32) {
        var digits = [CChar](repeating: 0, count: 24)
        var index = digits.count - 1
        var remaining = value
        let isNegative = remaining < 0
        if isNegative { remaining = -remaining }
        repeat {
            digits[index] = CChar(48 + remaining % 10)
            remaining /= 10
            index -= 1
        } while remaining > 0 && index >= 0
        if isNegative, index >= 0 {
            digits[index] = CChar(45)
            index -= 1
        }
        digits.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            _ = write(descriptor, base + index + 1, digits.count - index - 1)
        }
    }

    private static func writeException(_ exception: NSException) {
        var text = "\n=== UNCAUGHT EXCEPTION ===\n"
        text += "name: \(exception.name.rawValue)\n"
        text += "reason: \(exception.reason ?? "—")\n"
        text += "footprint-bytes \(PerformanceMonitor.physicalFootprint())\n"
        text += Breadcrumbs.formatted()
        text += "\n--- call stack ---\n"
        text += exception.callStackSymbols.joined(separator: "\n")
        text += "\n"

        let descriptor = reportDescriptor
        guard descriptor >= 0 else {
            log.fault("uncaught exception with no report file: \(text, privacy: .public)")
            return
        }
        text.withCString { pointer in
            _ = write(descriptor, pointer, strlen(pointer))
        }
        fsync(descriptor)
    }
}

/// A fixed-size ring of what the app was doing.
///
/// **A C buffer, not an array of `String`.** A crash report is written from
/// signal context where allocation is forbidden, so the breadcrumbs have to
/// already exist as bytes — an array of Swift strings would have to be walked
/// and copied at exactly the moment that is illegal.
///
/// Each entry is a fixed-width slot, overwritten in place, so recording a
/// breadcrumb never allocates either and the ring cannot grow.
nonisolated enum Breadcrumbs {
    static let slotWidth = 96
    static let slotCount = 100

    nonisolated(unsafe) private static var storage =
        [CChar](repeating: 0, count: slotWidth * slotCount)
    nonisolated(unsafe) private static var cursor = 0
    private static let lock = NSLock()

    /// Records one line. Safe from any thread; never allocates beyond the
    /// caller's own string.
    static func record(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let slot = cursor % slotCount
        cursor += 1
        let offset = slot * slotWidth
        // Clear the slot, then copy at most `slotWidth - 1` bytes so the entry
        // is always NUL-terminated even when the message is longer.
        for index in 0..<slotWidth { storage[offset + index] = 0 }
        var written = 0
        for byte in message.utf8 {
            guard written < slotWidth - 1 else { break }
            storage[offset + written] = CChar(bitPattern: byte)
            written += 1
        }
    }

    /// Writes the ring to a descriptor. Async-signal-safe.
    static func dump(to descriptor: Int32) {
        let header = "\n--- breadcrumbs (oldest first) ---\n"
        header.withCString { _ = write(descriptor, $0, strlen($0)) }
        let total = min(cursor, slotCount)
        let start = cursor > slotCount ? cursor % slotCount : 0
        for step in 0..<total {
            let slot = (start + step) % slotCount
            let offset = slot * slotWidth
            storage.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                let entry = base + offset
                let length = strnlen(entry, slotWidth)
                guard length > 0 else { return }
                _ = write(descriptor, entry, length)
                _ = write(descriptor, "\n", 1)
            }
        }
    }

    /// The readable form, for the paths where allocation is allowed.
    static func formatted() -> String {
        lock.lock()
        defer { lock.unlock() }
        var lines: [String] = []
        let total = min(cursor, slotCount)
        let start = cursor > slotCount ? cursor % slotCount : 0
        for step in 0..<total {
            let slot = (start + step) % slotCount
            let offset = slot * slotWidth
            let entry = storage[offset..<(offset + slotWidth)]
                .prefix { $0 != 0 }
                .map { UInt8(bitPattern: $0) }
            guard !entry.isEmpty else { continue }
            lines.append(String(decoding: entry, as: UTF8.self))
        }
        return "\n--- breadcrumbs (oldest first) ---\n" + lines.joined(separator: "\n") + "\n"
    }
}
