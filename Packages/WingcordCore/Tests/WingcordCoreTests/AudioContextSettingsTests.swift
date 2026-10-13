import Foundation
import Testing
@testable import WingcordCore

/// Discord's per-person sound settings, written by its own writer's rules
/// (module 386741).
@Suite("Audio context settings")
struct AudioContextSettingsTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("A voice defaults to as sent, a stream to 18")
    func defaults() {
        let settings = AudioContextSettings()
        #expect(settings.volume(of: UserID(rawValue: 1), in: .user) == 1)
        #expect(settings.volume(of: UserID(rawValue: 1), in: .stream) == 0.18)
        #expect(!settings.isMuted(UserID(rawValue: 1)))
    }

    @Test("A change is stamped, and back at the default the entry goes")
    func defaultsAreNotWritten() {
        var settings = AudioContextSettings()
        let person = UserID(rawValue: 7)
        settings.setVolume(0.5, of: person, in: .user, at: now)
        #expect(settings.users[person] == .init(volume: 0.5, modifiedAt: 1_800_000_000_000))

        // A hair off the default is the default — a slider dragged back by hand.
        settings.setVolume(1.001, of: person, in: .user, at: now)
        #expect(settings.users[person] == nil)

        settings.setMuted(true, of: person, at: now)
        #expect(settings.isMuted(person))
        #expect(settings.volume(of: person, in: .user) == 1)
        settings.setMuted(false, of: person, at: now)
        #expect(settings.users.isEmpty)
    }

    @Test("Each map keeps its newest 300")
    func capacity() {
        var settings = AudioContextSettings()
        for index in 0...300 {
            settings.setVolume(
                0.5, of: UserID(rawValue: UInt64(index + 1)), in: .stream,
                at: now.addingTimeInterval(Double(index))
            )
        }
        #expect(settings.streams.count == 300)
        #expect(settings.streams[UserID(rawValue: 1)] == nil, "the oldest went")
        #expect(settings.streams[UserID(rawValue: 301)] != nil)
    }
}
