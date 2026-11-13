import SwiftUI
import UniformTypeIdentifiers

/// A bug report's zip, as the save panel writes it.
///
/// Nonisolated: the system reads and writes a document off the main actor.
nonisolated struct BugReportFile: FileDocument {
    static var readableContentTypes: [UTType] { [.zip] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
