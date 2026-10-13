import AppKit
import Foundation
import WingcordCore

/// A file from a message, saved to the reader's Downloads folder — the file
/// card's Download, and a click on a file nothing here can show.
///
/// **Straight into Downloads, as a browser does**, with no panel: the viewer's
/// Save asks where because a picture somebody chose to keep is a decision; a
/// file somebody pressed Download on has already been decided about. A name
/// already taken gets the Finder's own " 2" suffix rather than replacing
/// what is there.
///
/// **Marked as downloaded from the internet** (`quarantineProperties`), so
/// Gatekeeper checks an app or a script before it opens — a file from a
/// stranger's message is exactly what that check exists for. And the Dock's
/// Downloads stack is told, as Safari tells it, so it bounces.
@MainActor
enum AttachmentDownloads {

    /// Downloads one attachment, reporting a failure in the reader's words.
    static func download(_ attachment: Attachment, model: AppModel) {
        download(from: attachment.url, named: attachment.filename, model: model)
    }

    /// The same, for a card that holds the file's link and name rather than
    /// the attachment — a text preview's Download.
    static func download(from link: String, named filename: String, model: AppModel) {
        guard let url = URL(string: link), InlineScannerSchemeCheck.isSafe(link) else { return }
        Task {
            do {
                let file = try await ImageStore.shared.download(url) { _ in }
                let destination = try place(file, named: filename)
                DistributedNotificationCenter.default().post(
                    name: Notification.Name("com.apple.DownloadFileFinished"),
                    object: destination.path
                )
            } catch {
                model.reportActionFailure("Couldn’t download \(filename).")
            }
        }
    }

    /// Moves a finished download into Downloads under a free name, quarantined.
    private static func place(_ file: URL, named filename: String) throws -> URL {
        let folder = try FileManager.default.url(
            for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        var destination = folder.appending(path: safeName(filename))
        var counter = 2
        let stem = destination.deletingPathExtension().lastPathComponent
        let ext = destination.pathExtension
        while FileManager.default.fileExists(atPath: destination.path) {
            let name = ext.isEmpty ? "\(stem) \(counter)" : "\(stem) \(counter).\(ext)"
            destination = folder.appending(path: name)
            counter += 1
        }
        try FileManager.default.moveItem(at: file, to: destination)
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineAgentNameKey as String: "Wingcord",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
        ]
        var placed = destination
        try? placed.setResourceValues(values)
        return destination
    }

    /// A name somebody else chose, made safe to write: no path separators, no
    /// leading dot that would hide it, never empty.
    nonisolated static func safeName(_ filename: String) -> String {
        let cleaned = filename
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = cleaned.drop { $0 == "." }
        return visible.isEmpty ? "download" : String(visible)
    }
}
