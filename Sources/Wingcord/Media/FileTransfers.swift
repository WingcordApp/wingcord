import AppKit
import Foundation
import os
import QuickLookUI
import UniformTypeIdentifiers
import WingcordCore

/// A file card's download, as the card draws it (docs/BETA3.md §7, R8).
nonisolated struct FileTransferState: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        /// Coming down. `fraction` is how far.
        case downloading
        /// In Downloads, at `savedURL`.
        case saved
        /// It stopped; the card offers to try again.
        case failed
    }

    var phase: Phase
    var fraction: Double = 0
    /// The file's size as Discord gave it, for "3.2 MB of 48 MB".
    var total: Int = 0
    /// Fetched for Quick Look, into a cache, rather than kept.
    var isPreview = false
    var savedURL: URL?
    /// Whether it landed a moment ago: the card says "Saved to Downloads" and
    /// shows a check, then settles on Show in Finder.
    var isFresh = false
    /// When it landed — the check pops in over the first instant of it.
    var savedAt: Date?

    var received: Int { Int(Double(total) * min(1, max(0, fraction))) }
}

/// Every file card's download: the ring's progress, the file once it's kept,
/// a failure to try again, and the copy Quick Look opens.
///
/// **Straight into Downloads, as a browser does** (`AttachmentDownloads`), and
/// now with the whole of it on the card: a ring that fills clockwise with a
/// stop in it (HIG: "When possible, use a determinate indicator", "let people
/// halt processing"), a check when it's there, then Show in Finder. A click on
/// the card itself is Quick Look — "Use its viewer for attachments or files
/// your app cannot open".
@MainActor
@Observable
final class FileTransfers {
    /// By attachment. What the transcript paints.
    private(set) var states: [AttachmentID: FileTransferState] = [:]

    @ObservationIgnored private var tasks: [AttachmentID: Task<Void, Never>] = [:]
    @ObservationIgnored private var cachedCopies: [AttachmentID: URL] = [:]
    @ObservationIgnored private var lastWrite: [AttachmentID: (fraction: Double, at: ContinuousClock.Instant)] = [:]

    /// How long the check stays before the button becomes Show in Finder.
    static let freshFor: Duration = .milliseconds(1600)

    // MARK: The card's controls

    /// The round button: download, stop, show in the Finder, try again.
    func pressButton(_ attachment: Attachment) {
        switch states[attachment.id]?.phase {
        case .downloading?:
            cancel(attachment.id)
        case .saved?:
            if let url = savedFile(attachment.id) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
                // Moved or deleted since: download it again.
                states[attachment.id] = nil
                save(attachment)
            }
        case .failed?, nil:
            save(attachment)
        }
    }

    /// Into Downloads under a free name, quarantined, the Dock's stack told.
    func save(_ attachment: Attachment) {
        start(attachment, isPreview: false)
    }

    /// Quick Look: the kept file where there is one, the cached copy where
    /// there is one, or a copy fetched now with the ring showing it.
    func preview(_ attachment: Attachment) {
        if let url = savedFile(attachment.id) ?? cachedCopy(attachment.id) {
            FilePreview.shared.show(url)
            return
        }
        guard states[attachment.id]?.phase != .downloading else { return }
        start(attachment, isPreview: true)
    }

    /// Asks for a place and saves there — the menu's Save As….
    func saveAs(_ attachment: Attachment, in window: NSWindow?) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = AttachmentDownloads.safeName(attachment.filename)
        panel.canCreateDirectories = true
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let destination = panel.url else { return }
            self?.start(attachment, isPreview: false, destination: destination)
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: handler) } else { handler(panel.runModal()) }
    }

    /// Opens the file in its default app, fetching it first where needed.
    func open(_ attachment: Attachment) {
        if let url = savedFile(attachment.id) ?? cachedCopy(attachment.id) {
            NSWorkspace.shared.open(url)
            return
        }
        start(attachment, isPreview: true, thenOpen: true)
    }

    func cancel(_ id: AttachmentID) {
        tasks[id]?.cancel()
        tasks[id] = nil
        states[id] = nil
        lastWrite[id] = nil
    }

    /// Where a kept file is, if it is still there.
    func savedFile(_ id: AttachmentID) -> URL? {
        guard let url = states[id]?.savedURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private func cachedCopy(_ id: AttachmentID) -> URL? {
        guard let url = cachedCopies[id], FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    // MARK: The download

    private func start(
        _ attachment: Attachment,
        isPreview: Bool,
        destination: URL? = nil,
        thenOpen: Bool = false
    ) {
        guard let source = URL(string: attachment.url), InlineScannerSchemeCheck.isSafe(attachment.url) else { return }
        let id = attachment.id
        tasks[id]?.cancel()
        let total = max(0, attachment.size)
        states[id] = FileTransferState(phase: .downloading, total: total, isPreview: isPreview)
        lastWrite[id] = nil
        // The store lives as long as the model, so the task holds it plainly;
        // only the progress hop, which may outlive nothing, holds it weakly.
        tasks[id] = Task {
            do {
                let file = try await ImageStore.shared.download(source) { [weak self] fraction in
                    Task { @MainActor in self?.progressed(id, fraction: fraction) }
                }
                try Task.checkCancellation()
                if isPreview {
                    let copy = try Self.cache(file, named: attachment.filename, id: id)
                    cachedCopies[id] = copy
                    states[id] = nil
                    if thenOpen { NSWorkspace.shared.open(copy) } else { FilePreview.shared.show(copy) }
                } else {
                    let placed = try destination.map { try AttachmentDownloads.place(file, at: $0) }
                        ?? AttachmentDownloads.place(file, named: attachment.filename)
                    DistributedNotificationCenter.default().post(
                        name: Notification.Name("com.apple.DownloadFileFinished"),
                        object: placed.path
                    )
                    states[id] = FileTransferState(
                        phase: .saved, fraction: 1, total: total, savedURL: placed, isFresh: true, savedAt: .now
                    )
                    settle(id)
                }
            } catch {
                if Task.isCancelled {
                    states[id] = nil
                } else {
                    states[id] = FileTransferState(phase: .failed, total: total, isPreview: isPreview)
                }
            }
            tasks[id] = nil
            lastWrite[id] = nil
        }
    }

    /// At most thirty writes a second, and only for a visible step: every
    /// write repaints the rows that carry the file.
    private func progressed(_ id: AttachmentID, fraction: Double) {
        guard var state = states[id], state.phase == .downloading else { return }
        let now = ContinuousClock.now
        if let last = lastWrite[id], fraction < 1,
           fraction - last.fraction < 0.01 || now - last.at < .milliseconds(33)
        {
            return
        }
        lastWrite[id] = (fraction, now)
        state.fraction = fraction
        states[id] = state
    }

    /// The check gives way to Show in Finder.
    private func settle(_ id: AttachmentID) {
        Task { [weak self] in
            try? await Task.sleep(for: Self.freshFor)
            guard let self, var state = states[id], state.phase == .saved, state.isFresh else { return }
            state.isFresh = false
            states[id] = state
        }
    }

    /// Moves a finished download into this run's preview folder, under the
    /// file's own name, so Quick Look's title is the name somebody sent.
    nonisolated static func cache(_ file: URL, named filename: String, id: AttachmentID) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "WingcordPreviews", directoryHint: .isDirectory)
            .appending(path: id.description, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appending(path: AttachmentDownloads.safeName(filename))
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: file, to: destination)
        return destination
    }
}

// MARK: - Quick Look

/// The system's Quick Look panel over one file.
///
/// **The panel looks for its controller along the responder chain**; the app
/// delegate answers for it (`WingcordAppDelegate`), and this is what both it
/// and a direct open hand the panel.
@MainActor
final class FilePreview: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = FilePreview()

    private var url: URL?

    func show(_ url: URL) {
        self.url = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    /// What the delegate's `beginPreviewPanelControl` gives the panel.
    func take(_ panel: QLPreviewPanel) {
        panel.dataSource = self
        panel.delegate = self
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { url == nil ? 0 : 1 }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let url = MainActor.assumeIsolated { self.url }
        return url.map { $0 as NSURL }
    }
}

// MARK: - Dragging a file out

/// A file card dragged to the Finder, Mail or the desktop: a file promise, kept
/// by downloading the file to wherever it was dropped (HIG: copies between apps,
/// with a menu command as the alternative — the card's Save As…).
nonisolated final class AttachmentFilePromise: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {
    let attachment: Attachment

    /// Promises still being kept: the provider holds its delegate weakly, and a
    /// drop is written after the drag has ended.
    private static let keeping = OSAllocatedUnfairLock(initialState: [ObjectIdentifier: AttachmentFilePromise]())
    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    init(attachment: Attachment) {
        self.attachment = attachment
        super.init()
        Self.keeping.withLock { $0[ObjectIdentifier(self)] = self }
    }

    /// The promised file's type, for the provider the canvas makes.
    var fileTypeIdentifier: String {
        let ext = (attachment.filename as NSString).pathExtension
        return (UTType(filenameExtension: ext) ?? .data).identifier
    }

    func release() {
        Self.keeping.withLock { _ = $0.removeValue(forKey: ObjectIdentifier(self)) }
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        AttachmentDownloads.safeName(attachment.filename)
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        Self.queue
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let finish = PromiseCompletion(call: completionHandler)
        guard let source = URL(string: attachment.url), InlineScannerSchemeCheck.isSafe(attachment.url) else {
            finish.call(CocoaError(.fileWriteUnknown))
            release()
            return
        }
        Task.detached { [self] in
            do {
                let file = try await ImageStore.shared.download(source) { _ in }
                try? FileManager.default.removeItem(at: url)
                try FileManager.default.moveItem(at: file, to: url)
                AttachmentDownloads.quarantine(url)
                finish.call(nil)
            } catch {
                finish.call(error)
            }
            release()
        }
    }
}

/// The file promise's completion, carried across the download.
nonisolated private struct PromiseCompletion: @unchecked Sendable {
    let call: (Error?) -> Void
}
