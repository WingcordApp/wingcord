import AppKit
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
import WingcordCore

// MARK: - A bug report (docs/BUG-REPORTING.md, phase 3)
//
// What the person writes, what the app adds, and the zip both become.
//
// **Nothing here sends anything.** A report is built into files the person can
// read in full ("See What's Sent") and save ("Save Report…"); `Reporting/
// Sending` sends exactly these files, the picture apart (phase 6).

/// What the report is about — guessed from where the reader is, and theirs to
/// change.
nonisolated enum BugArea: String, CaseIterable, Identifiable, Sendable, Codable {
    case messages
    case voice
    case video
    case screenShare
    case notifications
    case profiles
    case servers
    case appearance
    case settings
    case performance
    case crash
    case signIn
    case other

    var id: Self { self }

    var title: String {
        switch self {
        case .messages: "Messages"
        case .voice: "Voice"
        case .video: "Video"
        case .screenShare: "Screen Share"
        case .notifications: "Notifications"
        case .profiles: "Profiles"
        case .servers: "Servers & Channels"
        case .appearance: "Appearance"
        case .settings: "Settings"
        case .performance: "Speed & Freezes"
        case .crash: "Crash"
        case .signIn: "Signing In"
        case .other: "Something Else"
        }
    }

    var symbolName: String {
        switch self {
        case .messages: "bubble.left.and.bubble.right"
        case .voice: "waveform"
        case .video: "video"
        case .screenShare: "rectangle.on.rectangle"
        case .notifications: "bell"
        case .profiles: "person.crop.circle"
        case .servers: "number"
        case .appearance: "paintpalette"
        case .settings: "gearshape"
        case .performance: "gauge.with.dots.needle.33percent"
        case .crash: "exclamationmark.triangle"
        case .signIn: "key"
        case .other: "questionmark.circle"
        }
    }
}

/// How the sheet was opened — the report says so, because a report written
/// straight after a crash is a different kind of evidence.
nonisolated enum BugReportOrigin: Equatable, Sendable {
    case menu
    case slashCommand
    case settings
    /// The launch after a crash or a hang somebody force-quit, with what that
    /// run left behind.
    case afterCrash(PreviousRun.Ending)

    var logWord: String {
        switch self {
        case .menu: "menu"
        case .slashCommand: "/bug"
        case .settings: "settings"
        case .afterCrash(let ending): ending.kind == .hang ? "after a hang" : "after a crash"
        }
    }
}

/// The sheet's fields. **One draft for a bug and an idea** (D24): switching
/// between them keeps what was typed — `summary` is what happened or the
/// idea, `steps` the steps or how it would be used.
nonisolated struct BugReportDraft: Equatable, Sendable {
    var kind: ReportKind = .bug
    var summary = ""
    var steps = ""
    var area: BugArea = .other
    var includesDiagnostics = true
    /// Off by default (D21): a picture of somebody's window is theirs to
    /// offer.
    var includesScreenshot = false
    var origin: BugReportOrigin = .menu

    var isSubmittable: Bool {
        !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// A report as files, before it is zipped: exactly what would be sent.
nonisolated struct BugReportContents: Sendable {
    struct File: Identifiable, Sendable {
        enum Kind: Sendable { case text, json, image }

        var name: String
        var kind: Kind
        var data: Data
        /// One line on what the file is, for the list.
        var caption: String

        var id: String { name }
        var text: String? { kind == .image ? nil : String(decoding: data, as: UTF8.self) }
    }

    var files: [File]
    var created: Date

    var totalBytes: Int { files.reduce(0) { $0 + $1.data.count } }
}

// MARK: - Building

/// Collects, scrubs and lays out a report's files — off the main actor: the
/// log alone is up to 4 MB of text to read and scrub.
nonisolated enum BugReportBuilder {
    /// The newest this many crash and hang reports go with a report.
    static let crashesKept = 3
    /// The system's own diagnostics (MetricKit), newest first, within two weeks.
    static let systemReportsKept = 5
    static let systemReportsWithin: TimeInterval = 14 * 24 * 60 * 60

    static func build(
        draft: BugReportDraft,
        facts: SystemFacts,
        screenshot: Data?,
        directory: URL = CrashReporter.reportDirectory,
        log: LogStore? = Log.store,
        now: Date = Date()
    ) -> BugReportContents {
        let scrubber = log?.scrubber ?? LogScrubber.ephemeral()
        var files: [BugReportContents.File] = []

        files.append(.init(
            name: "report.txt",
            kind: .text,
            data: Data(summaryText(draft: draft, facts: facts, scrubber: scrubber, now: now).utf8),
            caption: "What you wrote, and this Mac in words"
        ))
        if let json = try? reportJSON(draft: draft, facts: facts, scrubber: scrubber, now: now) {
            files.append(.init(name: "report.json", kind: .json, data: json, caption: "The same, for the server to read"))
        }

        if draft.includesDiagnostics {
            if let log {
                // Scrubbed as it was written, and again now: a rule added since
                // a line was written still reaches it.
                let text = scrubber.scrub(log.export())
                files.append(.init(
                    name: "log.txt", kind: .text, data: Data(text.utf8),
                    caption: "What the app did, without names, words or addresses"
                ))
            }
            for report in crashReports(for: draft, in: directory) {
                guard let text = try? String(contentsOf: report, encoding: .utf8) else { continue }
                files.append(.init(
                    name: "crashes/" + report.lastPathComponent, kind: .text,
                    data: Data(scrubber.scrub(text).utf8),
                    caption: report.lastPathComponent.hasPrefix("hang-")
                        ? "A run that stopped answering" : "A run that crashed"
                ))
            }
            for report in systemReports(in: directory, now: now) {
                guard let text = try? String(contentsOf: report, encoding: .utf8) else { continue }
                files.append(.init(
                    name: "system/" + report.lastPathComponent, kind: .json,
                    data: Data(scrubber.scrub(text).utf8),
                    caption: "What macOS noticed: a hang, a crash, a spike"
                ))
            }
        }
        if draft.includesScreenshot, let screenshot {
            files.append(.init(
                name: "screenshot.png", kind: .image, data: screenshot,
                caption: "The Wingcord window, as it was"
            ))
        }
        return BugReportContents(files: files, created: now)
    }

    /// The report a person reads first.
    static func summaryText(draft: BugReportDraft, facts: SystemFacts, scrubber: LogScrubber, now: Date) -> String {
        let isIdea = draft.kind == .idea
        var text = isIdea ? "Wingcord feature idea\n" : "Wingcord bug report\n"
        text += "Written \(ISO8601DateFormatter().string(from: now)), from \(draft.origin.logWord)\n"
        text += "Area: \(draft.area.title)\n\n"
        text += (isIdea ? "The idea\n" : "What happened\n")
            + scrubber.scrub(draft.summary.trimmingCharacters(in: .whitespacesAndNewlines)) + "\n"
        let steps = draft.steps.trimmingCharacters(in: .whitespacesAndNewlines)
        if !steps.isEmpty {
            text += (isIdea ? "\nHow it would be used\n" : "\nSteps\n") + scrubber.scrub(steps) + "\n"
        }
        text += "\nThis Mac\n" + facts.summary + "\n"
        if case .afterCrash(let ending) = draft.origin {
            text += "\nWritten after \(ending.kind == .hang ? "a run that stopped answering" : "a crash"): "
                + ending.file.lastPathComponent + "\n"
        }
        text += "\n" + CrashReporter.mainImageLine
        return text
    }

    private struct ReportJSON: Encodable {
        var format = 1
        var kind: String
        var created: Date
        var origin: String
        var area: String
        var summary: String
        var steps: String
        var includesDiagnostics: Bool
        var includesScreenshot: Bool
        var facts: SystemFacts
        var image: String
    }

    static func reportJSON(draft: BugReportDraft, facts: SystemFacts, scrubber: LogScrubber, now: Date) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(ReportJSON(
            kind: draft.kind.rawValue,
            created: now,
            origin: draft.origin.logWord,
            area: draft.area.rawValue,
            summary: scrubber.scrub(draft.summary.trimmingCharacters(in: .whitespacesAndNewlines)),
            steps: scrubber.scrub(draft.steps.trimmingCharacters(in: .whitespacesAndNewlines)),
            includesDiagnostics: draft.includesDiagnostics,
            includesScreenshot: draft.includesScreenshot,
            facts: facts,
            image: CrashReporter.mainImageLine.trimmingCharacters(in: .whitespacesAndNewlines)
        ))
    }

    /// The crash or hang this report was written about, then the newest few.
    static func crashReports(for draft: BugReportDraft, in directory: URL) -> [URL] {
        var reports = Array(PreviousRun.reports(in: directory).prefix(crashesKept))
        if case .afterCrash(let ending) = draft.origin, !reports.contains(ending.file),
           FileManager.default.fileExists(atPath: ending.file.path(percentEncoded: false))
        {
            reports.insert(ending.file, at: 0)
        }
        return reports
    }

    static func systemReports(in directory: URL, now: Date) -> [URL] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys)
        )) ?? []
        let cutoff = now.addingTimeInterval(-systemReportsWithin)
        return contents
            .filter { $0.lastPathComponent.hasPrefix("system-") && $0.pathExtension == "json" }
            .filter { ((try? $0.resourceValues(forKeys: keys))?.contentModificationDate ?? .distantPast) > cutoff }
            // The name opens with the time it covers, so the names sort by age.
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .prefix(systemReportsKept)
            .map(\.self)
    }
}

// MARK: - The zip

nonisolated enum BugReportArchive {
    enum Failure: Error, LocalizedError {
        case couldNotWrite(String)

        var errorDescription: String? {
            switch self {
            case .couldNotWrite(let reason): "The report could not be written: \(reason)"
            }
        }
    }

    /// `Wingcord Report 2026-11-12 22.15`.
    static func name(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return "Wingcord Report \(formatter.string(from: date))"
    }

    /// The report as one zip: its files in a folder named for it, compressed.
    ///
    /// **The system's own zip**, through a coordinated read "for uploading" —
    /// which hands back a compressed copy of a folder, the same archive the
    /// Finder's Compress makes — rather than a zip writer of our own.
    static func zip(_ contents: BugReportContents) throws -> Data {
        let manager = FileManager.default
        let staging = manager.temporaryDirectory.appending(path: "wingcord-report-\(UUID().uuidString)")
        let folder = staging.appending(path: name(for: contents.created), directoryHint: .isDirectory)
        defer { try? manager.removeItem(at: staging) }
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            for file in contents.files {
                let url = folder.appending(path: file.name)
                try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try file.data.write(to: url)
            }
        } catch {
            throw Failure.couldNotWrite(error.localizedDescription)
        }

        var archive: Data?
        var readFailure: (any Error)?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordinationError) { zipped in
            do { archive = try Data(contentsOf: zipped) } catch { readFailure = error }
        }
        if let failure = coordinationError ?? (readFailure as NSError?) {
            throw Failure.couldNotWrite(failure.localizedDescription)
        }
        guard let archive else { throw Failure.couldNotWrite("the archive came back empty") }
        return archive
    }
}

// MARK: - The window, as a picture

/// A picture of the Wingcord window, taken before the sheet covers it.
///
/// **ScreenCaptureKit where Screen Recording is already allowed** — exactly
/// what is on screen, glass and video included — **and the window's own
/// layers otherwise**, which needs no permission and so never raises a prompt
/// from inside a bug report. The second picture is close; glass can come out
/// flat in it.
@MainActor
enum WindowSnapshot {
    /// A PNG of the main window, or nil when there is no window to take.
    static func capture() async -> Data? {
        guard let window = MainWindow.workspaceWindow, window.isVisible else { return nil }
        if CGPreflightScreenCaptureAccess(), let image = await captureWithScreenCaptureKit(window) {
            return png(image)
        }
        return renderLayers(of: window).flatMap(png)
    }

    private static func captureWithScreenCaptureKit(_ window: NSWindow) async -> CGImage? {
        let number = CGWindowID(window.windowNumber)
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let target = content.windows.first(where: { $0.windowID == number }) else { return nil }
            let filter = SCContentFilter(desktopIndependentWindow: target)
            let configuration = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            configuration.width = Int(filter.contentRect.width * scale)
            configuration.height = Int(filter.contentRect.height * scale)
            configuration.showsCursor = false
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            Log.info(.ui, "the window could not be captured: \(error)")
            return nil
        }
    }

    /// The window's view tree drawn into a bitmap by Core Animation.
    private static func renderLayers(of window: NSWindow) -> CGImage? {
        guard let view = window.contentView?.superview ?? window.contentView, let layer = view.layer else { return nil }
        let scale = window.backingScaleFactor
        let size = view.bounds.size
        let width = Int(size.width * scale)
        let height = Int(size.height * scale)
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        // The window's ground first, so a clear region is the window's
        // colour rather than a hole.
        context.setFillColor(window.backgroundColor.usingColorSpace(.sRGB)?.cgColor ?? NSColor.windowBackgroundColor.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // No flip: Core Animation renders a layer tree in the context's own
        // bottom-up space, flipped views and all.
        context.scaleBy(x: scale, y: scale)
        layer.render(in: context)
        return context.makeImage()
    }

    private static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
