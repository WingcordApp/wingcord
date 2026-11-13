import Darwin
import Foundation
import Synchronization
import Testing
@testable import Wingcord
@testable import WingcordCore

/// docs/BUG-REPORTING.md, phases 2–4: the app's half of the bug reporting
/// system.
@Suite("Bug reports")
struct BugReportingTests {

    private func temporaryFolder() throws -> URL {
        let folder = URL.temporaryDirectory.appending(path: "wingcord-report-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private var facts: SystemFacts {
        SystemFacts(
            appVersion: "1.0", appBuild: "42", bundleIdentifier: "dev.wingcord.Wingcord", macOS: "27.3",
            model: "Mac17,2", chip: "Apple M5", memory: "24 GB", processorCount: 10,
            displays: [.init(points: "1512×982", scale: 2, refreshRate: 120)],
            runningFor: "12s", footprint: "200 MB", thermalState: "nominal", lowPowerMode: false,
            appearance: "dark", reduceMotion: false, reduceTransparency: false, increaseContrast: false,
            language: "en", detailedLogging: false, changedSettings: ["messageBubbles"]
        )
    }

    // MARK: /bug

    @Test("/bug and /idea are offered for a bare slash, for their prefixes, and with words after them")
    func builtInMatching() {
        #expect(BuiltInCommand.matching("") == [.bug, .idea])
        #expect(BuiltInCommand.matching("b") == [.bug])
        #expect(BuiltInCommand.matching("i") == [.idea])
        #expect(BuiltInCommand.matching("idea pin my chats") == [.idea])
        #expect(BuiltInCommand.matching("ideas").isEmpty)
        #expect(BuiltInCommand.matching("BUG") == [.bug])
        #expect(BuiltInCommand.matching("bug the call dropped") == [.bug])
        #expect(BuiltInCommand.matching("bugs").isEmpty)
        #expect(BuiltInCommand.matching("ban").isEmpty)
        #expect(BuiltInCommand.matching("b something").isEmpty, "a prefix with words after it is not the command")
    }

    @Test("A draft that is /bug runs it, with the words after it, and a message is a message")
    func builtInInvocation() {
        let plain = BuiltInCommand.invocation(in: "/bug")
        #expect(plain?.command == .bug && plain?.argument == "")
        let worded = BuiltInCommand.invocation(in: "  /bug   the call went quiet \n")
        #expect(worded?.command == .bug && worded?.argument == "the call went quiet")
        let idea = BuiltInCommand.invocation(in: "/idea pin my chats")
        #expect(idea?.command == .idea && idea?.argument == "pin my chats")
        #expect(BuiltInCommand.invocation(in: "/bugfix") == nil)
        #expect(BuiltInCommand.invocation(in: "there is a /bug here") == nil)
        #expect(BuiltInCommand.invocation(in: "bug") == nil)
    }

    @Test("The Wingcord section's row runs the built-in, not an application's command")
    func builtInSection() throws {
        let section = try #require(BuiltInCommand.section(matching: "bu"))
        #expect(section.isBuiltIn)
        #expect(section.rows.map(\.name) == ["bug"])
        #expect(section.rows.first?.target == .builtIn(.bug))
        #expect(BuiltInCommand.section(matching: "zzz") == nil)
    }

    // MARK: The bundle

    @Test("A report holds what was written, the log, and the crash — scrubbed — and no picture unless asked")
    func bundleContents() throws {
        let folder = try temporaryFolder()
        let scrubber = LogScrubber(salt: Array("bundle".utf8), home: "/Users/alexandra")
        let log = LogStore.inMemory(scrubber: scrubber)
        log.write(.info, .gateway, "READY guilds=3")
        let crash = folder.appending(path: "crash-100.txt")
        try "\n=== SIGNAL 11 ===\nopened /Users/alexandra/Library/x 203.0.113.9\n".write(to: crash, atomically: true, encoding: .utf8)

        var draft = BugReportDraft()
        draft.summary = "It froze while I typed to me@example.com"
        draft.area = .messages
        let contents = BugReportBuilder.build(
            draft: draft, facts: facts, screenshot: Data([1, 2, 3]), directory: folder, log: log
        )
        let names = contents.files.map(\.name)
        #expect(names.contains("report.txt"))
        #expect(names.contains("report.json"))
        #expect(names.contains("log.txt"))
        #expect(names.contains("crashes/crash-100.txt"))
        #expect(!names.contains("screenshot.png"), "the picture went without being asked for")

        let report = try #require(contents.files.first { $0.name == "report.txt" }?.text)
        #expect(report.contains("It froze while I typed to <email>"))
        #expect(report.contains("Area: Messages"))
        let crashText = try #require(contents.files.first { $0.name == "crashes/crash-100.txt" }?.text)
        #expect(!crashText.contains("203.0.113.9"))
        #expect(!crashText.contains("/Users/alexandra"))
        #expect(try #require(contents.files.first { $0.name == "log.txt" }?.text).contains("READY guilds=3"))

        draft.includesScreenshot = true
        let withPicture = BugReportBuilder.build(draft: draft, facts: facts, screenshot: Data([1, 2, 3]), directory: folder, log: log)
        #expect(withPicture.files.contains { $0.name == "screenshot.png" })
    }

    @Test("Without diagnostics, a report is only what was written and the Mac in words")
    func bundleWithoutDiagnostics() throws {
        var draft = BugReportDraft()
        draft.summary = "Something"
        draft.includesDiagnostics = false
        let contents = BugReportBuilder.build(
            draft: draft, facts: facts, screenshot: nil, directory: try temporaryFolder(),
            log: LogStore.inMemory(scrubber: .ephemeral())
        )
        #expect(contents.files.map(\.name) == ["report.txt", "report.json"])
    }

    @Test("A report zips into one archive")
    func archive() throws {
        var draft = BugReportDraft()
        draft.summary = "Zip me"
        let contents = BugReportBuilder.build(
            draft: draft, facts: facts, screenshot: nil, directory: try temporaryFolder(),
            log: LogStore.inMemory(scrubber: .ephemeral())
        )
        let zip = try BugReportArchive.zip(contents)
        // "PK\u{3}\u{4}": a zip's local file header.
        #expect(zip.prefix(4) == Data([0x50, 0x4B, 0x03, 0x04]))
    }

    // MARK: The previous run

    @Test("Only crash and hang reports with something in them are offered, newest first")
    func previousRunReports() throws {
        let folder = try temporaryFolder()
        let manager = FileManager.default
        let old = folder.appending(path: "crash-1.txt")
        let empty = folder.appending(path: "crash-2.txt")
        let hang = folder.appending(path: "hang-3.txt")
        try "=== SIGNAL 6 ===".write(to: old, atomically: true, encoding: .utf8)
        manager.createFile(atPath: empty.path(percentEncoded: false), contents: Data())
        try "stopped answering".write(to: hang, atomically: true, encoding: .utf8)
        try manager.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: old.path(percentEncoded: false))
        try "{}".write(to: folder.appending(path: "system-1.json"), atomically: true, encoding: .utf8)

        let reports = PreviousRun.reports(in: folder).map(\.lastPathComponent)
        #expect(reports == ["hang-3.txt", "crash-1.txt"])
    }

    // MARK: System facts

    @Test("Changed settings are named, not valued, and per-person keys are counted")
    func changedSettings() {
        let names = SystemFacts.changedSettings(keys: [
            "messageBubbles", "NSWindow Frame main", "AppleLanguages", "draft.1046123456789611532",
            "volume.1046123456789611532", "textScale",
        ])
        #expect(names == ["messageBubbles", "textScale", "2 per-channel or per-person keys"])
    }

    // MARK: The watchdog's sampler

    @Test("A thread's stack can be read from another thread")
    func sampleAnotherThread() throws {
        nonisolated final class Box: @unchecked Sendable {
            var port: thread_act_t = 0
            let stop = Atomic<Bool>(false)
        }
        let box = Box()
        let started = DispatchSemaphore(value: 0)
        let thread = Thread {
            // Written before the signal, read after the wait: the semaphore
            // orders the two.
            box.port = pthread_mach_thread_np(pthread_self())
            started.signal()
            while !box.stop.load(ordering: .relaxed) { usleep(1_000) }
        }
        thread.start()
        started.wait()
        defer { box.stop.store(true, ordering: .relaxed) }

        let frames = UnsafeMutablePointer<UInt>.allocate(capacity: StackSampler.capacity)
        defer { frames.deallocate() }
        let depth = StackSampler.sample(box.port, into: frames)
        #expect(depth >= 3, "a sleeping thread has a kernel call, the loop and the thread's start under it")
        let lines = StackSampler.describe(Array(UnsafeBufferPointer(start: frames, count: depth)))
        #expect(lines.count == depth)
        #expect(lines.allSatisfy { $0.first?.isNumber == true })
    }

    // MARK: Detailed logging

    @Test("Time left reads as minutes and seconds")
    func timeLeft() {
        let logging = DetailedLogging()
        #expect(logging.remaining(at: .now) == "", "nothing is left of a window that is not open")
    }
}
