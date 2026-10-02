import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// A photo or video taken out of the Photos library as a file an upload can
/// read.
///
/// **Copied out, under the library's own name.** The file the picker hands
/// over is deleted when the import returns, so it goes to a folder this app
/// owns first — `Photos/<uuid>/`, beside `PastedFiles`' `Pasted/`.
///
/// **The representations are asked for in this order**: a JPEG or an MPEG-4,
/// which the picker's `.compatible` encoding offers for a HEIC photo and an
/// HEVC video, and otherwise whatever picture or movie the item is — a PNG
/// screenshot stays a PNG.
nonisolated struct PhotoLibraryFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .jpeg, importing: copy)
        FileRepresentation(importedContentType: .mpeg4Movie, importing: copy)
        FileRepresentation(importedContentType: .image, importing: copy)
        FileRepresentation(importedContentType: .movie, importing: copy)
    }

    private static func copy(_ received: ReceivedTransferredFile) throws -> PhotoLibraryFile {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "Photos", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: received.file.lastPathComponent)
        try FileManager.default.copyItem(at: received.file, to: url)
        return PhotoLibraryFile(url: url)
    }
}
