import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// Spotify's player object, read the way Discord's `SpotifyStore` reads it, and
/// a listen-along invitation as Discord's API answers with one.
struct SpotifyPlayerDecodeTests {

    private func playback(_ json: String) throws -> SpotifyPlayback {
        try JSONDecoder().decode(SpotifyPlayerDTO.self, from: Data(json.utf8)).domain
    }

    @Test func aPlayingTrackIsReadWithItsAlbumAndArtists() throws {
        let state = try playback(#"""
        {"device":{"id":"d1","is_active":true,"is_restricted":false,"name":"MacBook","type":"Computer","volume_percent":80},
         "progress_ms":97000,"is_playing":true,"repeat_state":"off",
         "context":{"type":"album","uri":"spotify:album:6TmEZKJtPJ9mPsMBmyteCE"},
         "item":{"id":"6gbmylJ7sB7NFfMfTQHosf","name":"Alberto Balsalm","duration_ms":310746,"type":"track","is_local":false,
           "album":{"id":"6TmEZKJtPJ9mPsMBmyteCE","name":"...I Care Because You Do","type":"album",
             "images":[{"height":640,"url":"https://i.scdn.co/image/ab67616d0000b2734bcecb123363f1f0f869257c","width":640}]},
           "artists":[{"id":"6kBDZFXuLrZgHnvmPu9NsG","name":"Aphex Twin"},{"id":"","name":"Nobody"}]}}
        """#)
        #expect(state.isPlaying)
        #expect(state.progress == 97000)
        #expect(state.contextURI == "spotify:album:6TmEZKJtPJ9mPsMBmyteCE")
        #expect(state.device?.isActive == true)
        let item = try #require(state.item)
        #expect(item.id == "6gbmylJ7sB7NFfMfTQHosf")
        #expect(item.imageURL?.absoluteString == "https://i.scdn.co/image/ab67616d0000b2734bcecb123363f1f0f869257c")
        // An artist with no id is dropped, as Discord drops it.
        #expect(item.artists.map(\.name) == ["Aphex Twin"])
    }

    @Test func aRelinkedTrackIsKnownByTheOneItCameFrom() throws {
        let state = try playback(#"""
        {"is_playing":true,"progress_ms":1,"item":{"id":"new","name":"T","duration_ms":1000,"type":"track","linked_from":{"id":"original"}}}
        """#)
        #expect(state.item?.id == "original")
    }

    @Test func anEpisodeIsFiledUnderItsShow() throws {
        let state = try playback(#"""
        {"is_playing":true,"progress_ms":1,"context":{"type":"playlist","uri":"spotify:playlist:x"},
         "item":{"id":"e1","name":"Episode","duration_ms":1000,"type":"episode","show":{"id":"s1","name":"The Show","images":[{"url":"https://i.scdn.co/image/show"}]}}}
        """#)
        #expect(state.item?.type == "episode")
        #expect(state.item?.albumName == "The Show")
        #expect(state.item?.artists.isEmpty == true)
        // A playlist's context would need a second request to know it is public.
        #expect(state.contextURI == nil)
    }

    /// **Captured** — `invite to listen along.har`, the message the invite
    /// POST answered with.
    @Test func theCapturedInvitationDecodesAsAListenAlong() throws {
        let json = #"""
        {"type":0,"content":"","mentions":[],"mention_roles":[],"attachments":[],"embeds":[],
         "timestamp":"2026-10-02T03:22:31.265000+00:00","edited_timestamp":null,"flags":0,"components":[],
         "id":"1555419685256449000","channel_id":"1424759145021837325",
         "author":{"id":"987654321987654321","username":"alexsample","global_name":"alex","discriminator":"0"},
         "pinned":false,"mention_everyone":false,"tts":false,
         "activity":{"type":3,"party_id":"spotify:987654321987654321","name_override":"Spotify",
           "icon_override":"spotify:ab67616d0000b2734bcecb123363f1f0f869257c"},
         "nonce":"1555419683966943232"}
        """#
        let message = try DiscordREST.decoder.decode(MessageDTO.self, from: Data(json.utf8)).domain
        let invite = try #require(message.listenAlong)
        #expect(invite.partyID == "spotify:987654321987654321")
        #expect(invite.name == "Spotify")
        #expect(invite.iconKey == "spotify:ab67616d0000b2734bcecb123363f1f0f869257c")
        #expect(!message.isEmpty)
    }

    @Test func anInvitationToSomethingElseIsNotAListenAlong() throws {
        let json = #"""
        {"type":0,"content":"","id":"1","channel_id":"2","author":{"id":"3","username":"u"},
         "timestamp":"2026-10-02T03:22:31.265000+00:00","activity":{"type":1,"party_id":"some-game-party"}}
        """#
        #expect(try DiscordREST.decoder.decode(MessageDTO.self, from: Data(json.utf8)).domain.listenAlong == nil)
    }
}
