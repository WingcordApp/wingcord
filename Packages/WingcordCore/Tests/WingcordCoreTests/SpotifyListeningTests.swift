import Foundation
import Testing
@testable import WingcordCore

/// The Listening activity Discord builds from what Spotify plays, and the
/// Spotify party it hangs a listen-along on.
struct SpotifyListeningTests {

    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func track(name: String = "Alberto Balsalm", artists: Int = 1, isLocal: Bool = false, albumType: String = "album") -> SpotifyPlayback.Item {
        SpotifyPlayback.Item(
            id: "6gbmylJ7sB7NFfMfTQHosf",
            name: name,
            duration: 310_746,
            albumID: "6TmEZKJtPJ9mPsMBmyteCE",
            albumName: "...I Care Because You Do",
            imageURL: URL(string: "https://i.scdn.co/image/ab67616d0000b2734bcecb123363f1f0f869257c"),
            albumType: albumType,
            artists: (0..<artists).map { SpotifyPlayback.Artist(id: "a\($0)", name: $0 == 0 ? "Aphex Twin" : "Artist;\($0)") },
            isLocal: isLocal
        )
    }

    @Test("A track becomes Discord's Listening activity, party and sync included")
    func activity() {
        let activity = SpotifyListening.activity(
            for: track(), startedAt: start, contextURI: "spotify:album:6TmEZKJtPJ9mPsMBmyteCE",
            partyID: "spotify:987654321987654321"
        )
        #expect(activity.type == 2)
        #expect(activity.name == "Spotify")
        #expect(activity.details == "Alberto Balsalm")
        #expect(activity.state == "Aphex Twin")
        #expect(activity.assets?.largeImage == "spotify:ab67616d0000b2734bcecb123363f1f0f869257c")
        #expect(activity.assets?.largeText == "...I Care Because You Do")
        #expect(activity.timestamps?.start == 1_790_000_000_000)
        #expect(activity.timestamps?.end == 1_790_000_000_000 + 310_746)
        #expect(activity.party?.id == "spotify:987654321987654321")
        #expect(activity.syncID == "6gbmylJ7sB7NFfMfTQHosf")
        #expect(activity.flags == 48)
        #expect(activity.metadata?.contextURI == "spotify:album:6TmEZKJtPJ9mPsMBmyteCE")
        #expect(activity.metadata?.artistIDs == ["a0"])
    }

    @Test("Five artists at most, with their own semicolons taken out")
    func artists() {
        let activity = SpotifyListening.activity(for: track(artists: 7), startedAt: start, contextURI: nil, partyID: "spotify:1")
        #expect(activity.state == "Aphex Twin; Artist1; Artist2; Artist3; Artist4")
        #expect(activity.metadata?.artistIDs.count == 5)
    }

    @Test("A long name is cut at 125 with an ellipsis, a single keeps no album line")
    func trimmed() {
        let long = String(repeating: "x", count: 140)
        let activity = SpotifyListening.activity(for: track(name: long, albumType: "single"), startedAt: start, contextURI: nil, partyID: "spotify:1")
        #expect(activity.details == String(repeating: "x", count: 125) + "...")
        #expect(activity.assets?.largeText == nil)
    }

    @Test("A local file has nothing to sync to")
    func local() {
        let activity = SpotifyListening.activity(for: track(isLocal: true), startedAt: start, contextURI: nil, partyID: "spotify:1")
        #expect(activity.syncID == nil)
        #expect(activity.flags == 0)
        #expect(activity.metadata == nil)
    }

    @Test("The start holds steady unless the player moved by more than a second and a half")
    func steadyStart() {
        let now = start.addingTimeInterval(100)
        let first = SpotifyListening.startTime(progress: 60_000, at: now, previous: nil)
        #expect(first == start.addingTimeInterval(40))
        #expect(SpotifyListening.startTime(progress: 61_200, at: now.addingTimeInterval(1), previous: first) == first)
        #expect(SpotifyListening.startTime(progress: 120_000, at: now.addingTimeInterval(1), previous: first) != first)
    }

    @Test("A Spotify party is told by its prefix, and its art by its key")
    func party() {
        #expect(SpotifyListening.partyID(for: UserID(rawValue: 7)) == "spotify:7")
        #expect(SpotifyListening.isSpotifyParty("spotify:7"))
        #expect(!SpotifyListening.isSpotifyParty("i-123-pc-456"))
        #expect(SpotifyListening.imageURL(forAsset: "spotify:abc")?.absoluteString == "https://i.scdn.co/image/abc")
        #expect(SpotifyListening.imageURL(forAsset: "mp:external/abc") == nil)
    }
}
