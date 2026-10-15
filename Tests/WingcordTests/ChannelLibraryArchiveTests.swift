import Foundation
import Testing
@testable import Wingcord
@testable import WingcordCore

/// The inspector's older items, found by search: folded in once each, newest
/// first, and reachable by the viewer like the transcript's own.
@Suite("Inspector archive")
@MainActor
struct ChannelLibraryArchiveTests {
    private let channelID = ChannelID(rawValue: 77)

    private func message(_ id: UInt64) -> Message {
        Message(id: MessageID(rawValue: id << 22), channelID: channelID, authorID: UserID(rawValue: 1), content: "m\(id)")
    }

    @Test("Pages fold in once each, newest first")
    func receive() {
        var archive = LibraryArchive()
        archive.receive([message(30), message(10)])
        archive.receive([message(20), message(30)])
        #expect(archive.messages.map { $0.id.rawValue >> 22 } == [30, 20, 10])
    }

    @Test("Media is finished only when both its filters are")
    func exhaustion() {
        var archive = LibraryArchive()
        archive.exhausted = [.image]
        #expect(!archive.isExhausted(for: .media))
        archive.exhausted.insert(.video)
        #expect(archive.isExhausted(for: .media))
        #expect(!archive.isExhausted(for: .files))
    }

    @Test("A message found by search is one the viewer can open")
    func knownMessage() {
        let model = AppModel()
        #expect(model.knownMessage(message(5).id, in: channelID) == nil)
        var archive = LibraryArchive()
        archive.receive([message(5)])
        model.libraryArchives[LibraryArchiveKey(channelID: channelID, kind: .files)] = archive
        #expect(model.knownMessage(message(5).id, in: channelID)?.content == "m5")
    }
}
