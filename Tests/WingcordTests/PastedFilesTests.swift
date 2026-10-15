import AppKit
import Foundation
import Testing
@testable import Wingcord

/// What a paste into the composer attaches — `PastedFiles`, on pasteboards of
/// its own so the tests never touch the reader's clipboard.
@Suite("Pasted files")
struct PastedFilesTests {

    private func pasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("wingcord-test-\(UUID().uuidString)"))
    }

    /// A one-pixel PNG, made rather than stored.
    private func png() throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32
        ))
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    @Test("Files copied in the Finder are pasted as those files")
    func files() throws {
        let board = pasteboard()
        let file = FileManager.default.temporaryDirectory.appending(path: "pasted-\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: file)
        board.clearContents()
        board.writeObjects([file as NSURL])
        #expect(PastedFiles.read(from: board) == [file])
    }

    @Test("A picture with no file behind it becomes image.png")
    func picture() throws {
        let board = pasteboard()
        let data = try png()
        board.clearContents()
        board.setData(data, forType: .png)
        let url = try #require(PastedFiles.read(from: board)?.first)
        #expect(url.lastPathComponent == "image.png")
        #expect(try Data(contentsOf: url) == data)
    }

    @Test("A screenshot's TIFF is sent as PNG")
    func tiff() throws {
        let board = pasteboard()
        let tiff = try #require(NSBitmapImageRep(data: try png())?.tiffRepresentation)
        board.clearContents()
        board.setData(tiff, forType: .tiff)
        let url = try #require(PastedFiles.read(from: board)?.first)
        #expect(url.pathExtension == "png")
        #expect(NSBitmapImageRep(data: try Data(contentsOf: url)) != nil)
    }

    @Test("Text copied with a picture of itself behind it pastes as text")
    func textFirst() throws {
        let board = pasteboard()
        board.clearContents()
        board.declareTypes([.string, .png], owner: nil)
        board.setString("words somebody copied", forType: .string)
        board.setData(try png(), forType: .png)
        #expect(PastedFiles.read(from: board) == nil)
    }

    @Test("A copied picture carrying its address as text is still a picture")
    func pictureFirst() throws {
        let board = pasteboard()
        board.clearContents()
        board.declareTypes([.png, .string], owner: nil)
        board.setData(try png(), forType: .png)
        board.setString("https://example.com/cat.png", forType: .string)
        #expect(PastedFiles.read(from: board)?.first?.lastPathComponent == "image.png")
    }

    @Test("Plain text is nobody's file")
    func text() {
        let board = pasteboard()
        board.clearContents()
        board.setString("yeah", forType: .string)
        #expect(PastedFiles.read(from: board) == nil)
    }

    @Test("Whether a paste carries files is answered from the types alone, in read's order")
    func hasFiles() throws {
        let files = pasteboard()
        let file = FileManager.default.temporaryDirectory.appending(path: "pasted-\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: file)
        files.clearContents()
        files.writeObjects([file as NSURL])
        #expect(PastedFiles.hasFiles(on: files))

        let picture = pasteboard()
        picture.clearContents()
        picture.setData(try png(), forType: .png)
        #expect(PastedFiles.hasFiles(on: picture))

        let text = pasteboard()
        text.clearContents()
        text.setString("yeah", forType: .string)
        #expect(!PastedFiles.hasFiles(on: text))
    }

    /// The bug: the field reads text alone, so AppKit turned Paste off with a
    /// picture on the clipboard and ⌘V never reached the code that takes it.
    @Test("Paste stays on in the composer while the clipboard holds a picture")
    @MainActor
    func pasteStaysOn() throws {
        let board = pasteboard()
        board.clearContents()
        board.setData(try png(), forType: .png)
        let field = MarkdownTextView()
        field.pasteboard = board
        field.onPasteFiles = { _ in true }
        let paste = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        #expect(field.validateMenuItem(paste))
        #expect(field.validateUserInterfaceItem(paste))
    }
}
