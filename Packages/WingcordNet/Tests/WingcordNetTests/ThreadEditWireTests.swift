import Foundation
import Testing
@testable import WingcordCore
@testable import WingcordNet

/// A thread write carries only what it changes — Discord's own writes are
/// this narrow (`867455`).
@Suite("Thread edits on the wire")
struct ThreadEditWireTests {
    private func json(_ edit: ThreadEdit) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try #require(String(data: encoder.encode(ThreadEditBody(edit)), encoding: .utf8))
    }

    @Test("A pin is the whole bitfield and nothing else")
    func pin() throws {
        let flags = ChannelFlags(rawValue: 1 << 1 | 1 << 21)
        #expect(try json(ThreadEdit(flags: flags)) == #"{"flags":2097154}"#)
    }

    @Test("A lock on a closed thread closes it again in the same write")
    func lockClosed() throws {
        #expect(try json(ThreadEdit(archived: true, locked: true)) == #"{"archived":true,"locked":true}"#)
    }

    @Test("The edit sheet's fields go under Discord's keys")
    func sheet() throws {
        let edit = ThreadEdit(name: "Help", autoArchiveMinutes: 1440, rateLimitPerUser: 30)
        #expect(try json(edit) == #"{"auto_archive_duration":1440,"name":"Help","rate_limit_per_user":30}"#)
    }

    @Test("Tags are strings, and an untouched edit is empty")
    func tags() throws {
        #expect(try json(ThreadEdit(appliedTags: [ForumTagID(rawValue: 42)])) == #"{"applied_tags":["42"]}"#)
        #expect(ThreadEdit().isEmpty)
        #expect(!ThreadEdit(invitable: false).isEmpty)
    }
}
