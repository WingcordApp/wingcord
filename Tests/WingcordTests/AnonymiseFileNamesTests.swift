import AppKit
import Foundation
import Testing
@testable import Wingcord
import WingcordCore

/// Vencord's AnonymiseFileNames on the composer's files: which are renamed
/// as their send begins, how, and the tile's own toggle.
@Suite("AnonymiseFileNames")
@MainActor
struct AnonymiseFileNamesTests {

    private func settings(_ configure: (AppSettings) -> Void = { _ in }) -> AppSettings {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "wingcord.tests.\(UUID())")!)
        configure(settings)
        return settings
    }

    private func file(_ name: String, anonymise: Bool? = nil) -> PendingAttachment {
        var file = PendingAttachment(url: URL(fileURLWithPath: "/nonexistent/\(name)"))
        file.anonymise = anonymise
        return file
    }

    @Test("Off, as a plugin is until it is switched on, and then nothing is renamed")
    func offByDefault() {
        let settings = settings()
        #expect(!settings.anonymisesFileNames)
        #expect(settings.anonymisesByDefault)
        #expect(settings.anonymisingMethod == .randomCharacters)
        #expect(settings.randomisedLength == 7)
        #expect(settings.consistentFileName == "image")
        let files = [file("cat.png"), file("dog.png", anonymise: true)]
        #expect(PendingAttachment.anonymising(files, settings: settings).map(\.filename) == ["cat.png", "dog.png"])
    }

    @Test("On, every file is renamed unless its tile said otherwise")
    func tilesDecide() {
        let settings = settings {
            $0.anonymisesFileNames = true
            $0.anonymisingMethod = .consistent
        }
        let files = [file("cat.png"), file("notes.tar.gz", anonymise: true), file("keep.jpg", anonymise: false)]
        let sent = PendingAttachment.anonymising(files, settings: settings)
        #expect(sent.map(\.filename) == ["image.png", "image.tar.gz", "keep.jpg"])
        // Only the name changes: the same files, with what they arrived as.
        #expect(sent.map(\.id) == files.map(\.id))
        #expect(sent.map(\.fileKind) == files.map(\.fileKind))
    }

    @Test("With Anonymise by default off, only a tile switched on is renamed")
    func defaultOff() {
        let settings = settings {
            $0.anonymisesFileNames = true
            $0.anonymisesByDefault = false
            $0.anonymisingMethod = .timestamp
        }
        let moment = Date(timeIntervalSince1970: 1_759_840_123.456)
        let sent = PendingAttachment.anonymising([file("a.png"), file("b.mov", anonymise: true)], settings: settings, now: moment)
        #expect(sent.map(\.filename) == ["a.png", "1759840123456.mov"])
    }

    @Test("Random Characters takes the length setting, held to 1…255")
    func randomLength() {
        let settings = settings {
            $0.anonymisesFileNames = true
            $0.randomisedLength = 12
        }
        let name = PendingAttachment.anonymising([file("photo.jpeg")], settings: settings)[0].filename
        #expect(name.count == 12 + ".jpeg".count)
        #expect(name.hasSuffix(".jpeg"))
        settings.randomisedLength = 0
        #expect(settings.randomisedLength == 1)
        settings.randomisedLength = 9_000
        #expect(settings.randomisedLength == 255)
    }

    @Test("The settings are kept")
    func persisted() {
        let suite = UserDefaults(suiteName: "wingcord.tests.\(UUID())")!
        let first = AppSettings(defaults: suite)
        first.anonymisesFileNames = true
        first.anonymisesByDefault = false
        first.anonymisingMethod = .timestamp
        first.randomisedLength = 9
        first.consistentFileName = "file"
        let again = AppSettings(defaults: suite)
        #expect(again.anonymisesFileNames)
        #expect(!again.anonymisesByDefault)
        #expect(again.anonymisingMethod == .timestamp)
        #expect(again.randomisedLength == 9)
        #expect(again.consistentFileName == "file")
    }

    /// The plugin's button sets the opposite of what it shows, and keeps it.
    @Test("The tile's toggle flips what it shows and keeps the answer on the file")
    func toggle() throws {
        let model = AppModel()
        let channel = ChannelID(rawValue: 1001)
        let staged = file("cat.png")
        model.mutateBox(channel) { $0.attachments = [staged] }
        let shown = AppSettings.shared.anonymisesByDefault
        model.toggleAttachmentAnonymise(staged.id, in: channel)
        #expect(try #require(model.messages(in: channel)?.attachments.first).anonymise == !shown)
        model.toggleAttachmentAnonymise(staged.id, in: channel)
        #expect(try #require(model.messages(in: channel)?.attachments.first).anonymise == shown)
    }

    @Test("The plugin's icons resolve", arguments: [DiscordGlyph.anonymous, DiscordGlyph.notAnonymous])
    func glyphs(name: String) throws {
        #expect(DiscordGlyph.owns(name))
        let image = try #require(NSImage.symbol(named: name))
        #expect(image.size.width > 0 && image.size.height > 0)
    }
}
