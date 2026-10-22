import AppKit
import CoreServices
import Observation
import WingcordCore

// MARK: - Asking a browser for its tabs
//
// AppleScript through `/usr/bin/osascript`, not `NSAppleScript`: that one is
// main-thread only and waits for the browser to answer, and a browser busy
// loading a page can take seconds. A child process answers on its own time and
// can be stopped. Its Apple Events are Wingcord's for Automation's purposes —
// the system asks about the app responsible for the process — so the consent
// prompt names Wingcord, with Info.plist's NSAppleEventsUsageDescription.

@Observable
@MainActor
final class BrowserTabReader {

    enum Answer: Equatable {
        case pages([BrowserTab])
        /// The reader declined Automation for this browser.
        case denied
        /// Not running, not scriptable, or no answer in time.
        case unavailable
    }

    /// Browsers the reader declined, as last asked — what the Activity pane
    /// points at System Settings for.
    private(set) var deniedBrowsers: Set<String> = []

    func pages(of bundleIdentifier: String) async -> Answer {
        guard let script = BrowserTabs.script(for: bundleIdentifier),
              !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
        else { return .unavailable }
        // Asked without prompting first: an answer of "would need consent" means
        // the prompt is about to show, and must not be cut short by the timeout.
        let permission = Self.permission(for: bundleIdentifier)
        NowPlayingMonitor.trace("Automation of \(bundleIdentifier): \(permission)")
        if permission == OSStatus(errAEEventNotPermitted) {
            deniedBrowsers.insert(bundleIdentifier)
            return .denied
        }
        let asking = permission == OSStatus(errAEEventWouldRequireUserConsent)
        if asking { NowPlayingMonitor.trace("asking for Automation of \(bundleIdentifier)") }
        let started = ContinuousClock.now
        let result = await Self.run(script, timeout: asking ? .seconds(120) : .seconds(2))
        NowPlayingMonitor.trace(
            "\(bundleIdentifier) answered \(result.output.count) characters in "
                + "\((ContinuousClock.now - started).formatted(.units(allowed: [.milliseconds])))"
                + (result.exitedCleanly ? "" : ", not cleanly")
        )
        if BrowserTabs.isPermissionDenied(result.errors) {
            deniedBrowsers.insert(bundleIdentifier)
            return .denied
        }
        deniedBrowsers.remove(bundleIdentifier)
        guard result.exitedCleanly else {
            NowPlayingMonitor.trace("\(bundleIdentifier) gave no tabs: \(result.errors.prefix(200))")
            return .unavailable
        }
        return .pages(BrowserTabs.tabs(from: result.output))
    }

    /// `noErr`, `errAEEventNotPermitted`, `errAEEventWouldRequireUserConsent`
    /// or `procNotFound` — without showing anything.
    private static func permission(for bundleIdentifier: String) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleIdentifier)
        guard let descriptor = target.aeDesc else { return OSStatus(procNotFound) }
        return AEDeterminePermissionToAutomateTarget(descriptor, typeWildCard, typeWildCard, false)
    }

    private struct Result: Sendable {
        var output: String
        var errors: String
        var exitedCleanly: Bool
    }

    /// Runs the script and waits for it — **every blocking call on a GCD
    /// thread**, never the main actor's and never one of Swift's cooperative
    /// threads, which an `osascript` waiting on a busy browser must not hold.
    private nonisolated static func run(_ script: String, timeout: Duration) async -> Result {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        let seconds = Double(timeout.components.seconds)
        // A lookup nobody waits for any more stops its process too.
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        try process.run()
                    } catch {
                        continuation.resume(returning: Result(output: "", errors: error.localizedDescription, exitedCleanly: false))
                        return
                    }
                    let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds, execute: watchdog)
                    // Out first, then errors: `osascript` writes one or the
                    // other, and both are a line long.
                    let answer = output.fileHandleForReading.readDataToEndOfFile()
                    let complaint = errors.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    watchdog.cancel()
                    continuation.resume(returning: Result(
                        output: String(decoding: answer, as: UTF8.self),
                        errors: String(decoding: complaint, as: UTF8.self),
                        exitedCleanly: process.terminationReason == .exit && process.terminationStatus == 0
                    ))
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}
