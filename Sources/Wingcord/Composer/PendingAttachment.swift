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
    /// Which of Discord's file icons it wears, and whether it is a picture or
    /// a video — decided once, from the name and the type it arrived with, as
    /// Discord's upload decides `classification` in its constructor: a file
    /// renamed in Modify Attachment keeps its icon, and an SVG is web code,
    /// not a picture.
    let fileKind: AttachmentFileKind
    /// A description for screen readers, if the reader has written one.
    var altText: String?
    var isSpoiler = false
    /// The tile's own answer to AnonymiseFileNames once it has been toggled —
    /// the plugin's mark on an upload; nil follows "Anonymise by default".
    var anonymise: Bool?
    /// What makes it a Discord clip — shared from the clips library, never
    /// set on a file dropped in the composer.
    var clip: ClipUpload?

    init(url: URL, id: UUID = UUID()) {
        self.id = id
        self.url = url
        filename = url.lastPathComponent
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
        size = values?.fileSize ?? 0
        contentType = values?.contentType
        fileKind = AttachmentFileKind(filename: filename, contentType: contentType?.preferredMIMEType)
    }

    var isImage: Bool { fileKind == .image }
    var isVideo: Bool { fileKind == .video }

    var sizeLabel: String { DiscordFileSize.text(size) }

    /// The same file, under a new name, as the bytes at `url` — a converted
    /// or compressed copy keeps everything the reader set on it.
    func replaced(by url: URL, named filename: String) -> PendingAttachment {
        var copy = PendingAttachment(url: url, id: id)
        copy.filename = filename
        copy.altText = altText
        copy.isSpoiler = isSpoiler
        copy.anonymise = anonymise
        copy.clip = clip
        return copy
    }

    /// What the upload handshake needs. Built here so the shape the wire wants
    /// is derived in one place from the value the composer holds.
    var uploadRequest: UploadRequest {
        UploadRequest(
            filename: filename,
            size: size,
            altText: altText,
            isSpoiler: isSpoiler,
            clip: clip
        )
    }

    static func == (lhs: PendingAttachment, rhs: PendingAttachment) -> Bool {
        lhs.id == rhs.id
            && lhs.url == rhs.url
            && lhs.filename == rhs.filename
            && lhs.altText == rhs.altText
            && lhs.isSpoiler == rhs.isSpoiler
            && lhs.anonymise == rhs.anonymise
            && lhs.clip == rhs.clip
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// Whether AnonymiseFileNames renames this file when it is sent.
    func isAnonymised(by settings: AppSettings) -> Bool {
        settings.anonymisesFileNames && (anonymise ?? settings.anonymisesByDefault)
    }

    /// AnonymiseFileNames as the plugin runs it, on `uploadFiles`: each file it
    /// is on for takes a new name as its send begins, by the settings of the
    /// moment — so a refused send handed back to the composer carries the new
    /// names, and sending it again draws new ones, as the plugin's do.
    static func anonymising(
        _ files: [PendingAttachment],
        settings: AppSettings = .shared,
        now: Date = .now
    ) -> [PendingAttachment] {
        var generator = SystemRandomNumberGenerator()
        return files.map { file in
            guard file.isAnonymised(by: settings) else { return file }
            var renamed = file
            renamed.filename = FileNameAnonymiser.anonymise(
                file.filename,
                method: settings.anonymisingMethod,
                length: settings.randomisedLength,
                consistentName: settings.consistentFileName,
                now: now,
                using: &generator
            )
            return renamed
        }
    }
}

/// Why a file could not be staged, in Discord's words — its upload error's
/// title and help (DESIGN-NOTES §14).
enum AttachmentRefusal: Hashable, Sendable {
    /// Over the limit. `compressible` are the pictures and videos among the
    /// files, which Send Compressed can shrink to fit.
    case tooLarge(limit: Int, premium: PremiumTier, compressible: [URL])
    /// The message's files together over Discord's total.
    case totalTooLarge
    case tooMany(limit: Int)
    /// A file with nothing in it — and a folder, which a drop hands over as one.
    case empty
    /// The send itself failed, in Discord's words or the transport's. The tray
    /// is already the one place a file's bad news is shown, so a refused upload
    /// goes there rather than opening a second surface for the same event.
    case sendFailed(String)

    var title: String? {
        switch self {
        case .tooLarge, .totalTooLarge: AttachmentLimits.tooLargeTitle
        case .tooMany: AttachmentLimits.tooManyTitle
        case .empty: AttachmentLimits.emptyTitle
        case .sendFailed: nil
        }
    }

    var help: String {
        switch self {
        case .tooLarge(let limit, let premium, let compressible):
            compressible.contains(where: MediaCompressor.isPicture)
                ? AttachmentLimits.compressHelp(limit: limit)
                : AttachmentLimits.tooLargeHelp(limit: limit, premium: premium)
        case .totalTooLarge: AttachmentLimits.totalTooLargeHelp
        case .tooMany(let limit): AttachmentLimits.tooManyHelp(limit: limit)
        case .empty: AttachmentLimits.emptyHelp
        case .sendFailed(let reason): reason
        }
    }

    /// What Send Compressed would shrink, where it is offered.
    var compressible: [URL] {
        if case .tooLarge(_, _, let files) = self { files } else { [] }
    }

    /// Whether Always Compress Images speaks for any of them.
    var offersAlwaysCompress: Bool { compressible.contains(where: MediaCompressor.isPicture) }
}
