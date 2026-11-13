import AppKit
import Observation
import WingcordCore

/// The bug report's state, app-wide (docs/BUG-REPORTING.md D21, D24, D28).
///
/// **Ways in, one card**: Help ▸ Report a Bug… and Suggest a Feature…, `/bug`
/// and `/idea` in the composer, Settings, and the prompt on the launch after
/// a crash. Each calls `open`, which takes the window's picture first — the
/// card is drawn inside the window, so a picture taken after it opened would
/// be a picture of the card.
///
/// **The draft outlives the card.** A tester is often asked to turn on
/// detailed logging, close the card, make the problem happen again and come
/// back; what they had written is still there. A report that is sent or
/// saved starts the next one empty.
///
/// **Send, with Save Report… beside it** (phase 6): a report goes to the
/// reports service; a bug can still be saved as a file — offline, or when
/// the service turns it away.
@Observable
@MainActor
final class BugReporter {
    static let shared = BugReporter()

    /// The card, while it is up.
    struct Request: Identifiable, Equatable {
        let id = UUID()
    }

    /// Which page of the card is showing.
    enum Step: Equatable {
        case form
        /// "See What's Sent": every file, as it would go.
        case contents
        /// The report went: its id, to quote.
        case sent
        /// Your Reports: what this Mac sent, and what became of it.
        case history
    }

    var request: Request?
    var step: Step = .form
    var draft = BugReportDraft()
    /// The window as it was before the card covered it, when there was one.
    private(set) var screenshot: Data?
    private(set) var screenshotPreview: NSImage?
    private(set) var isOpening = false

    /// What "See What's Sent" shows, and the draft it was built from.
    private(set) var contents: BugReportContents?
    @ObservationIgnored private var contentsDraft: BugReportDraft?
    private(set) var isBuildingContents = false

    private(set) var isSaving = false
    /// The zip, while the save panel is up.
    var exportDocument: BugReportFile?
    var isExporting = false
    /// Why the last save did not happen, in words.
    var failure: String?

    private(set) var isSending = false
    /// Why the last send did not happen.
    private(set) var sendFailure: ReportSendError?
    /// The report that just went, for the page that says so.
    private(set) var sent: SentReport?
    /// Your Reports was opened on its own (from Settings), so its way out is
    /// Close rather than Back.
    private(set) var historyIsStandalone = false

    /// The launch-time question after a crash or a hang (D21: asked every
    /// time, never sent on its own).
    var crashPrompt: PreviousRun.Ending?

    /// The reports service — or, in the demo, a stand-in that sends nothing.
    @ObservationIgnored let service: any ReportService

    init(service: any ReportService = BugReporter.defaultService()) {
        self.service = service
    }

    static func defaultService() -> any ReportService {
        LaunchOptions.current.usesDemoFixtures ? DemoReportService() : ReportUploader.standard()
    }

    // MARK: Opening

    /// Opens the card: the picture first, then the card over it.
    func open(_ origin: BugReportOrigin, kind: ReportKind = .bug, model: AppModel, prefill: String? = nil) async {
        guard request == nil, !isOpening else { return }
        isOpening = true
        defer { isOpening = false }

        MainWindow.raise()
        // A crash's report is about the run that crashed; this window has
        // nothing to show of it.
        if case .afterCrash = origin {
            setScreenshot(nil)
        } else {
            setScreenshot(await WindowSnapshot.capture())
        }

        let isFresh = draft.summary.isEmpty && draft.steps.isEmpty
        draft.origin = origin
        // A crash is reported as a bug, whichever way the last draft was.
        draft.kind = origin.isAfterCrash ? .bug : kind
        if isFresh || origin != .menu {
            draft.area = Self.guessArea(origin: origin, model: model)
        }
        if let prefill, !prefill.isEmpty {
            draft.summary = draft.summary.isEmpty ? prefill : draft.summary + "\n" + prefill
        }
        if screenshot == nil { draft.includesScreenshot = false }
        failure = nil
        sendFailure = nil
        sent = nil
        step = .form
        request = Request()
        Log.info(.app, "the \(public: draft.kind.rawValue) report opened from \(public: origin.logWord)")
    }

    /// Opens the card on Your Reports, with nothing to write (Settings).
    func openHistory() {
        guard request == nil, !isOpening else { return }
        MainWindow.raise()
        historyIsStandalone = true
        sent = nil
        step = .history
        request = Request()
        refreshHistory()
    }

    func close() {
        request = nil
        step = .form
        contents = nil
        contentsDraft = nil
        sent = nil
        historyIsStandalone = false
    }

    /// Where the reader is says what the report is probably about.
    static func guessArea(origin: BugReportOrigin, model: AppModel) -> BugArea {
        if case .afterCrash(let ending) = origin {
            return ending.kind == .hang ? .performance : .crash
        }
        if model.isScreenSharing || model.watchedStreamUserID != nil { return .screenShare }
        if model.connectedVoiceChannelID != nil { return model.isCameraOn ? .video : .voice }
        switch model.connectionState {
        case .signedOut, .failed: return .signIn
        default: break
        }
        if case .settings = origin { return .settings }
        return model.selectedChannelID == nil ? .other : .messages
    }

    private func setScreenshot(_ data: Data?) {
        screenshot = data
        screenshotPreview = data.flatMap(NSImage.init(data:))
    }

    // MARK: Pages

    func showContents() {
        step = .contents
        Task { await buildContentsIfNeeded() }
    }

    func showForm() {
        step = .form
    }

    func showHistory() {
        step = .history
        refreshHistory()
    }

    private func refreshHistory() {
        Task { await SentReports.shared.refresh(using: service) }
    }

    /// Builds the files from the draft as it stands, unless they already are.
    func buildContentsIfNeeded() async {
        if contents != nil, contentsDraft == draft { return }
        isBuildingContents = true
        defer { isBuildingContents = false }
        let draft = draft
        let facts = SystemFacts.gather()
        let screenshot = screenshot
        let built = await Task.detached(priority: .userInitiated) {
            BugReportBuilder.build(draft: draft, facts: facts, screenshot: screenshot)
        }.value
        contents = built
        contentsDraft = draft
    }

    // MARK: Sending

    /// Sends the report: built and zipped as Save would, then handed to the
    /// service. Sent: the card turns to its id, and the next report starts
    /// empty. Not sent: it says why, and the draft stays.
    func send() async {
        guard draft.isSubmittable, !isSending else { return }
        isSending = true
        sendFailure = nil
        failure = nil
        defer { isSending = false }

        let draft = draft
        let upload: ReportUpload
        do {
            upload = try await makeUpload(for: draft)
        } catch {
            failure = error.localizedDescription
            return
        }
        do {
            let report = try await service.send(upload)
            SentReports.shared.add(report)
            Log.info(.app, "the \(public: draft.kind.rawValue) report was sent as \(public: report.reportID)"
                + (report.wasRepeat ? " (counted into an open report)" : "")
                + (report.missingParts.isEmpty ? "" : ", without \(public: report.missingParts.joined(separator: ", "))"))
            sent = report
            self.draft = BugReportDraft()
            contents = nil
            contentsDraft = nil
            setScreenshot(nil)
            step = .sent
        } catch {
            sendFailure = error
            Log.info(.app, "the report could not be sent: \(public: error.logWord)")
        }
    }

    /// The JSON, the zip without the picture, and the picture on its own.
    private func makeUpload(for draft: BugReportDraft) async throws -> ReportUpload {
        var bundle: Data?
        if draft.kind == .bug, draft.includesDiagnostics {
            await buildContentsIfNeeded()
            if var files = contents {
                // The picture travels on its own, so a published report can
                // show it without its diagnostics (D26).
                files.files.removeAll { $0.kind == .image }
                bundle = try await Task.detached(priority: .userInitiated) {
                    try BugReportArchive.zip(files)
                }.value
            }
        }
        var fitted: Data?
        if draft.includesScreenshot, let picture = screenshot {
            fitted = await Task.detached(priority: .userInitiated) { ScreenshotFitting.fit(picture) }.value
        }

        var attachments: [ReportSubmission.Part] = []
        if bundle != nil { attachments.append(.bundle) }
        if fitted != nil { attachments.append(.screenshot) }

        let crash = await Self.crashSignature(for: draft.origin)
        let submission = ReportSubmission.make(
            draft: draft,
            crash: crash,
            attachments: attachments,
            scrubber: Log.store?.scrubber ?? .ephemeral()
        )
        return ReportUpload(submission: submission, bundle: bundle, screenshot: fitted, title: Self.title(of: draft))
    }

    /// The crash a report after a crash is about, read from what it left.
    private static func crashSignature(for origin: BugReportOrigin) async -> CrashSignature? {
        guard case .afterCrash(let ending) = origin else { return nil }
        return await Task.detached(priority: .userInitiated) {
            guard let text = try? String(contentsOf: ending.file, encoding: .utf8) else { return nil }
            return CrashSignature.read(text, kind: ending.kind == .hang ? .hang : .crash)
        }.value
    }

    /// The first line of what was written, for Your Reports.
    static func title(of draft: BugReportDraft) -> String {
        let line = draft.summary
            .split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return line.count > 80 ? String(line.prefix(79)) + "…" : line
    }

    /// The sent page's Done: the card closes, the next report starts empty.
    func finishSent() {
        close()
    }

    // MARK: Saving

    /// Builds the zip, then hands it to the save panel.
    func save() async {
        guard draft.isSubmittable, !isSaving else { return }
        isSaving = true
        failure = nil
        await buildContentsIfNeeded()
        guard let contents else {
            isSaving = false
            return
        }
        do {
            let data = try await Task.detached(priority: .userInitiated) {
                try BugReportArchive.zip(contents)
            }.value
            exportDocument = BugReportFile(data: data)
            isExporting = true
        } catch {
            failure = error.localizedDescription
            isSaving = false
        }
    }

    /// The save panel's answer. Saved: shown in the Finder, the card closes,
    /// and the next report starts empty.
    func finishExport(_ result: Result<URL, any Error>) {
        isSaving = false
        exportDocument = nil
        switch result {
        case .success(let url):
            Log.info(.app, "a bug report was saved (\(bytes: (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))")
            NSWorkspace.shared.activateFileViewerSelecting([url])
            draft = BugReportDraft()
            close()
        case .failure(let error):
            // Cancelling the panel is not a failure worth a word.
            if (error as NSError).code != NSUserCancelledError {
                failure = error.localizedDescription
            }
        }
    }

    /// The file the save panel suggests.
    var exportName: String {
        BugReportArchive.name(for: contents?.created ?? Date())
    }

    // MARK: After a crash

    /// Asks, once, about what the last run left — a moment after launch, so
    /// the window is up behind the question.
    func offerPreviousRunReport() {
        guard let ending = PreviousRun.unoffered, crashPrompt == nil else { return }
        crashPrompt = ending
    }

    func answerCrashPrompt(report: Bool, model: AppModel) {
        guard let ending = crashPrompt else { return }
        PreviousRun.markOffered()
        crashPrompt = nil
        guard report else { return }
        Task { await open(.afterCrash(ending), model: model) }
    }
}

private extension BugReportOrigin {
    var isAfterCrash: Bool {
        if case .afterCrash = self { return true }
        return false
    }
}
