import Testing
@testable import WingcordCore

/// Discord's file icons, by its own rules (`453771`'s `T`).
struct AttachmentFileKindTests {

    @Test("A content type decides before the name", arguments: [
        ("x.txt", "image/png", AttachmentFileKind.image),
        ("logo.svg", "image/svg+xml", .webcode),
        ("art.psd", "image/vnd.adobe.photoshop", .photoshop),
        ("clip.bin", "video/mp4", .video),
    ])
    func byType(_ filename: String, _ type: String, _ kind: AttachmentFileKind) {
        #expect(AttachmentFileKind(filename: filename, contentType: type) == kind)
    }

    @Test("Without a type, the name", arguments: [
        ("Report.PDF", AttachmentFileKind.acrobat),
        ("app-icons.txt", .document),
        ("notes.md", .document),
        ("backup.tar.gz", .archive),
        ("main.swift", .unknown),
        ("main.py", .code),
        ("sheet.csv", .spreadsheet),
        ("page.html", .webcode),
        ("song.flac", .audio),
        ("design.sketch", .sketch),
        ("vector.ai", .ai),
        ("photo.png", .unknown),
        ("", .unknown),
    ])
    func byName(_ filename: String, _ kind: AttachmentFileKind) {
        #expect(AttachmentFileKind(filename: filename, contentType: nil) == kind)
    }

    /// `.ae` is not anchored in Discord's rule.
    @Test("Discord's unanchored After Effects rule")
    func afterEffects() {
        #expect(AttachmentFileKind(filename: "project.aep", contentType: nil) == .ae)
        #expect(AttachmentFileKind(filename: "my.aesthetic.txt", contentType: nil) == .ae)
    }

    @Test("A Photoshop file draws Discord's ps icon")
    func iconNames() {
        #expect(AttachmentFileKind.photoshop.iconName == "icon-file-ps")
        #expect(AttachmentFileKind.document.iconName == "icon-file-document")
    }
}
