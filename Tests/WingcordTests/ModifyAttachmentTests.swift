import Foundation
import Testing
@testable import Wingcord
import WingcordCore
import WingcordNet

/// Modify Attachment's Save, and how its spoiler reaches the wire.
@Suite("Modify Attachment")
@MainActor
struct ModifyAttachmentTests {

    private let channel = ChannelID(rawValue: 1001)

    private func staged(_ model: AppModel) -> PendingAttachment {
        let attachment = PendingAttachment(url: URL(fileURLWithPath: "/nonexistent/cat.png"))
        model.mutateBox(channel) { $0.attachments = [attachment] }
        return attachment
    }

    @Test("Save sets the name, the description and the spoiler at once")
    func save() {
        let model = AppModel()
        let attachment = staged(model)
        model.modifyAttachment(attachment.id, in: channel, filename: " dog.png ", altText: "  a dog asleep ", isSpoiler: true)
        let saved = model.messages(in: channel)?.attachments.first
        #expect(saved?.filename == "dog.png")
        #expect(saved?.altText == "a dog asleep")
        #expect(saved?.isSpoiler == true)
        #expect(saved?.uploadRequest.wireFilename == "SPOILER_dog.png")
    }

    @Test("An empty name keeps the file's own, and an empty description is none")
    func emptyFields() {
        let model = AppModel()
        let attachment = staged(model)
        model.modifyAttachment(attachment.id, in: channel, filename: "dog.png", altText: "a dog", isSpoiler: false)
        model.modifyAttachment(attachment.id, in: channel, filename: "  ", altText: " ", isSpoiler: false)
        let saved = model.messages(in: channel)?.attachments.first
        #expect(saved?.filename == "dog.png")
        #expect(saved?.altText == nil)
    }

    /// The box is held on by such a name and Save hands back the box's own
    /// value, so the name alone has to carry the spoiler — and once only.
    @Test("A name already starting SPOILER_ is a spoiler on the wire, prefixed once")
    func spoilerName() {
        let named = UploadRequest(filename: "SPOILER_dog.png", size: 1, isSpoiler: false)
        #expect(named.wireFilename == "SPOILER_dog.png")
        let both = UploadRequest(filename: "SPOILER_dog.png", size: 1, isSpoiler: true)
        #expect(both.wireFilename == "SPOILER_dog.png")
    }

    /// Discord's upload decides `classification` once, in its constructor.
    @Test("A file keeps the icon it arrived with when it is renamed")
    func fileKind() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "ModifyAttachmentTests-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let picture = folder.appending(path: "cat.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: picture)
        let drawing = folder.appending(path: "logo.svg")
        try Data("<svg/>".utf8).write(to: drawing)

        let model = AppModel()
        let attachment = PendingAttachment(url: picture)
        let svg = PendingAttachment(url: drawing)
        model.mutateBox(channel) { $0.attachments = [attachment, svg] }
        #expect(attachment.fileKind == .image)
        #expect(attachment.isImage)
        // An SVG is web code to Discord, so it is not shown as a picture and
        // asks for no description.
        #expect(svg.fileKind == .webcode)
        #expect(!svg.isImage)

        model.modifyAttachment(attachment.id, in: channel, filename: "notes.zip", altText: nil, isSpoiler: false)
        let renamed = try #require(model.messages(in: channel)?.attachments.first)
        #expect(renamed.filename == "notes.zip")
        #expect(renamed.fileKind == .image)
    }
}
