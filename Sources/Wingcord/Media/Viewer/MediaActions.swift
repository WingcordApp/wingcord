import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

/// Saving, copying and opening — the three things a reader does with a picture
/// once they have looked at it.
///
/// **One object, and it is what the toolbar's state comes from.** A save is a
/// panel, a network transfer and a file move, and each of those can fail
/// differently; a button that fires a detached task and forgets can only ever
/// report success. The progress the button draws and the message it shows on a
/// failure are the same object's properties.
@Observable
@MainActor
final class MediaActions {
    /// 0...1 while a save is running, nil when nothing is. Optional rather than
    /// a separate flag: "how far along" and "is it running" are one fact, and
    /// two properties for one fact drift.
    private(set) var saveProgress: Double?
    /// The last thing that went wrong, in the reader's words. Cleared by the
    /// next attempt.
    private(set) var failure: String?
    /// The file just written, so the toolbar can offer to show it in the Finder
    /// rather than leaving the reader to go and find it.
    private(set) var savedURL: URL?

    private var task: Task<Void, Never>?

    /// Puts the asset's own URL on the pasteboard.
    ///
    /// The **source** URL, not the resized rendition the viewer happens to be
    /// showing: a link that carries this viewer's decode ceiling in a query
    /// parameter is a link to a smaller picture than the one that was sent.
    func copyLink(_ item: MediaItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(item.sourceURL.absoluteString, forType: .string)
    }

    /// Puts the picture itself on the pasteboard, so it can be pasted into
    /// anything that takes one.
    ///
    /// The frame currently on screen, which for an animation is the frame the
    /// reader is looking at — pasting frame zero of a GIF somebody has scrubbed
    /// to the middle of is the wrong picture.
    func copyImage(_ image: CGImage) {
        let representation = NSBitmapImageRep(cgImage: image)
        guard let data = representation.representation(using: .png, properties: [:]) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: .png)
    }

    func openInBrowser(_ item: MediaItem) {
        NSWorkspace.shared.open(item.sourceURL)
    }

    func revealSavedFile() {
        guard let savedURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([savedURL])
    }

    /// Asks where, then streams it there.
    ///
    /// A sheet rather than `runModal`: a modal run loop stops the video playing
    /// behind it, which makes choosing a folder look like a hang.
    ///
    /// **A save deliberately outlives the viewer.** The task holds this object,
    /// so closing the lightbox on a half-finished download still writes the file
    /// somebody asked for — cancelling it there would throw away work on a
    /// gesture that means "I am done looking", not "stop saving". Nothing here
    /// writes into a view: the last two properties are read by a control that
    /// may already be gone, which costs nothing.
    func save(_ item: MediaItem) {
        guard task == nil else { return }
        failure = nil
        savedURL = nil
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.task = nil }
            guard let destination = await self.askWhereToSave(item) else { return }
            self.saveProgress = 0
            do {
                // A strong capture, deliberately: the enclosing task already
                // holds this object for the length of the transfer, so weakening
                // it here would only be a second, later reference to the same
                // lifetime — and the compiler says so.
                let file = try await ImageStore.shared.download(item.sourceURL) { progress in
                    Task { @MainActor in self.saveProgress = progress }
                }
                guard !Task.isCancelled else { return }
                // The downloaded file is the caller's the moment it arrives and
                // is reclaimed if it is left; a move rather than a copy, and
                // over anything already there, because the panel already asked.
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: file, to: destination)
                self.savedURL = destination
            } catch is CancellationError {
                // Closing the viewer mid-save is not a failure to report.
            } catch {
                self.failure = "Couldn’t save \(item.filename)."
            }
            self.saveProgress = nil
        }
    }

    private func askWhereToSave(_ item: MediaItem) async -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.filename
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        // Named from the content type when there is one, so the panel offers the
        // right extension and does not append a second copy of it.
        if let contentType = item.contentType, let type = UTType(mimeType: contentType) {
            panel.allowedContentTypes = [type]
        }
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
            return panel.runModal() == .OK ? panel.url : nil
        }
        let response = await panel.beginSheetModal(for: window)
        return response == .OK ? panel.url : nil
    }
}
