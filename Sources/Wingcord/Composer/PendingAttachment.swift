import AppKit
import Foundation
import UniformTypeIdentifiers
import WingcordCore
import WingcordNet

/// A file staged in the composer, before it is sent.
///
/// **A value keyed on a file on disk, not the bytes.** A half-gigabyte video
/// held in memory from the moment it is dropped until the moment it is sent is
/// half a gigabyte resident for as long as somebody takes to finish typing —
/// and the upload streams from the file anyway. What is held here is a URL, a
/// size, and a poster small enough to draw.
///
/// `id` is minted rather than derived from the path: the same picture dropped
/// twice is two attachments, and Discord accepts that.
struct PendingAttachment: Identifiable, Hashable, Sendable {
    let id: UUID
    /// Where the bytes are. A security-scoped bookmark is not needed — the app
    /// is unsandboxed, and a dropped or chosen file stays readable.
    var url: URL
    var filename: String
    var size: Int
    var contentType: UTType?
    /// A description for screen readers, if the reader has written one.
    var altText: String?
    var isSpoiler = false

    init(url: URL, id: UUID = UUID()) {
        self.id = id
        self.url = url
        filename = url.lastPathComponent
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
        size = values?.fileSize ?? 0
        contentType = values?.contentType
    }

    var isImage: Bool { contentType?.conforms(to: .image) ?? false }
    var isVideo: Bool { contentType?.conforms(to: .movie) ?? false }

    /// The SF Symbol for a file with no picture to show.
    ///
    /// Named from the type tree rather than from the extension: `.mpeg4Movie`
    /// and `.quickTimeMovie` are both `.movie`, and a list of extensions is a
    /// list that goes stale.
    var symbolName: String {
        guard let contentType else { return "doc" }
        if contentType.conforms(to: .movie) { return "film" }
        if contentType.conforms(to: .audio) { return "waveform" }
        if contentType.conforms(to: .pdf) { return "doc.richtext" }
        if contentType.conforms(to: .archive) { return "doc.zipper" }
        if contentType.conforms(to: .sourceCode) || contentType.conforms(to: .plainText) {
            return "doc.text"
        }
        return "doc"
    }

    var sizeLabel: String { AttachmentLimits.describe(bytes: size) }

    /// What the upload handshake needs. Built here so the shape the wire wants
    /// is derived in one place from the value the composer holds.
    var uploadRequest: UploadRequest {
        UploadRequest(
            filename: filename,
            size: size,
            altText: altText,
            isSpoiler: isSpoiler
        )
    }

    static func == (lhs: PendingAttachment, rhs: PendingAttachment) -> Bool {
        lhs.id == rhs.id
            && lhs.url == rhs.url
            && lhs.altText == rhs.altText
            && lhs.isSpoiler == rhs.isSpoiler
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Why a file could not be staged.
///
/// A reason rather than a flag: "that file is too big for this account" and
/// "that file is not there any more" need different sentences, and only one of
/// them mentions Nitro.
enum AttachmentRefusal: Hashable, Sendable {
    case tooLarge(filename: String, size: Int, limit: Int)
    case tooMany(limit: Int)
    case unreadable(filename: String)
    /// The send itself failed, in Discord's words or the transport's. The tray
    /// is already the one place a file's bad news is shown, so a refused upload
    /// goes there rather than opening a second surface for the same event.
    case sendFailed(String)

    var message: String {
        switch self {
        case .tooLarge(let filename, let size, let limit):
            """
            \(filename) is \(AttachmentLimits.describe(bytes: size)). \
            This account can send up to \(AttachmentLimits.describe(bytes: limit)) here.
            """
        case .tooMany(let limit):
            "A message can carry \(limit) files."
        case .unreadable(let filename):
            "\(filename) could not be read."
        case .sendFailed(let reason):
            reason
        }
    }
}
