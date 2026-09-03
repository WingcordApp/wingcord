import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// Decoding the two halves of a Go Live credential.
///
/// **A stream is a second media session, and these are the frames that describe
/// it.** `STREAM_CREATE` carries the key and the `rtc_server_id`;
/// `STREAM_SERVER_UPDATE` carries the endpoint and the token. Neither half
/// alone opens anything, and — exactly as a call's `VOICE_STATE_UPDATE` and
/// `VOICE_SERVER_UPDATE` do — they arrive in no guaranteed order.
///
/// **These are the real frames.** Opcode 18 was sent against a live account and
/// the two replies below are what came back, verbatim out of the trace, trimmed
/// of nothing. Discord does not dispatch `STREAM_CREATE` to a peer who is not
/// watching, so the only way to see one was to create a stream and read the
/// answer — which is why this client had to be built before its wire shape
/// could be confirmed.
///
/// The capture corrected one thing immediately: **`rtc_channel_id` is a field.**
/// The documentation says a stream's media session id is one less than its
/// `rtc_server_id`, and in the capture it is — `…905` beside `…906`. It is also
/// sent outright, so nothing here derives it. An arithmetic relationship that
/// holds in one capture is not a contract.
struct GoLiveDecodeTests {

    private static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    // MARK: STREAM_CREATE

    /// A real `STREAM_CREATE` for a direct-message call, exactly as captured.
    @Test("A stream create yields its key, its owner and both RTC ids")
    func streamCreate() throws {
        let event = try Self.decode(StreamEventDTO.self, """
        {
          "paused": false,
          "region": "bucharest",
          "rtc_channel_id": "1544564589096993916",
          "rtc_server_id": "1544564589099948566",
          "stream_key": "call:1424759145021837325:987654321987654321",
          "viewer_ids": []
        }
        """)
        #expect(event.ownerID == UserID(rawValue: 987_654_321_987_654_321))
        #expect(event.channelID == ChannelID(rawValue: 1_424_759_145_021_837_325))
        #expect(event.rtc_server_id == RTCServerID(rawValue: 1_544_564_589_099_948_566))
        #expect(event.rtc_channel_id == RTCServerID(rawValue: 1_544_564_589_096_993_916))
        #expect(event.region == "bucharest")
    }

    /// **`STREAM_UPDATE` carries no RTC server, and that must not be an error.**
    /// The same type decodes both, and a required field here would throw away
    /// every viewer-count update — which is the one signal for "somebody is
    /// watching me".
    @Test("A stream update without RTC ids still decodes")
    func streamUpdateWithoutRTCServer() throws {
        let event = try Self.decode(StreamEventDTO.self, """
        {
          "stream_key": "guild:900:901:902",
          "viewer_ids": ["903", "904"]
        }
        """)
        #expect(event.rtc_server_id == nil)
        #expect(event.rtc_channel_id == nil)
        #expect(event.ownerID == UserID(rawValue: 902))
        // `guild:<guild>:<channel>:<user>` puts the channel third.
        #expect(event.channelID == ChannelID(rawValue: 901))
        #expect(event.viewer_ids?.count == 2)
    }

    // MARK: STREAM_SERVER_UPDATE

    /// A guild stream identifies with the **guild**, exactly as a guild call
    /// does.
    @Test("A guild stream's server id is the guild")
    func guildStreamServerID() throws {
        let update = try Self.decode(StreamServerUpdateDTO.self, """
        {
          "stream_key": "guild:900:901:902",
          "guild_id": "900",
          "token": "a-stream-token",
          "endpoint": "rotterdam1234.discord.media:443"
        }
        """)
        let server = try #require(update.domain)
        #expect(server.serverID == "900")
        #expect(server.streamKey == "guild:900:901:902")
        #expect(server.token == "a-stream-token")
        #expect(server.endpoint == "rotterdam1234.discord.media:443")
    }

    /// A real `STREAM_SERVER_UPDATE` for a call stream: **`guild_id` is
    /// explicitly null and there is no `channel_id` at all**, so the DM channel
    /// has to come out of the key.
    ///
    /// That value is the honest mirror of `VOICE_SERVER_UPDATE` and it is *not*
    /// what the stream's identify wants — see `streamIdentityIsTheRTCChannel`.
    @Test("A call stream's server update names no guild, so the channel comes from the key")
    func callStreamServerID() throws {
        let update = try Self.decode(StreamServerUpdateDTO.self, """
        {
          "endpoint": "c-otp01-8702aeca.discord.media:443",
          "guild_id": null,
          "stream_key": "call:1424759145021837325:987654321987654321",
          "token": "a-stream-token"
        }
        """)
        let server = try #require(update.domain)
        #expect(server.serverID == "1424759145021837325")
        #expect(server.endpoint == "c-otp01-8702aeca.discord.media:443")
        #expect(update.ownerID == UserID(rawValue: 987_654_321_987_654_321))
    }

    /// **A null endpoint is "the region is being reassigned, wait", not a
    /// target.** `VOICE_SERVER_UPDATE` has the identical rule, and a client
    /// that ignores it opens a socket to `wss://null`.
    @Test("A stream server with no endpoint yields nothing to connect to")
    func nullEndpointIsRefused() throws {
        let update = try Self.decode(StreamServerUpdateDTO.self, """
        {
          "stream_key": "guild:900:901:902",
          "guild_id": "900",
          "token": "a-stream-token",
          "endpoint": null
        }
        """)
        #expect(update.domain == nil)
    }

    // MARK: What the pair adds up to

    /// **The media session is read, not derived** — and this is the test that
    /// keeps it that way.
    ///
    /// In the captured frame `rtc_channel_id` happens to be `rtc_server_id`
    /// minus one, which is what the documentation describes. A client that
    /// computes it instead of reading it agrees with the server exactly as long
    /// as that holds and has no way to notice when it stops. The field is
    /// authoritative; the arithmetic is a coincidence this asserts is *only* a
    /// coincidence.
    @Test("The media session is the RTC channel the create sent, not arithmetic")
    func mediaSessionIsReadNotDerived() throws {
        let event = try Self.decode(StreamEventDTO.self, """
        {
          "stream_key": "call:1:2",
          "rtc_server_id": "1544564589099948566",
          "rtc_channel_id": "1544564589096993916"
        }
        """)
        let channel = try #require(event.rtc_channel_id)
        #expect(channel.rawValue == 1_544_564_589_096_993_916)

        // A server that ever stops keeping them adjacent is followed, not
        // second-guessed: the field wins.
        let apart = try Self.decode(StreamEventDTO.self, """
        {"stream_key": "call:1:2", "rtc_server_id": "900", "rtc_channel_id": "17"}
        """)
        #expect(apart.rtc_channel_id == RTCServerID(rawValue: 17))
    }

    /// **A stream identifies against its own RTC channel**, not the DM channel
    /// and not the guild.
    ///
    /// Measured: identifying with the DM channel — the value
    /// `StreamServerUpdateDTO.domain` produces — was answered `4006 Session is
    /// no longer valid.` twenty milliseconds after the frame went out, on a
    /// stream the server had just created for us.
    @Test("A stream's identity is its RTC channel, which is not its server update's channel")
    func streamIdentityIsTheRTCChannel() throws {
        let created = try Self.decode(StreamEventDTO.self, """
        {
          "stream_key": "call:1424759145021837325:987654321987654321",
          "rtc_server_id": "1544564589099948566",
          "rtc_channel_id": "1544564589096993916"
        }
        """)
        let update = try Self.decode(StreamServerUpdateDTO.self, """
        {
          "endpoint": "c-otp01-8702aeca.discord.media:443",
          "guild_id": null,
          "stream_key": "call:1424759145021837325:987654321987654321",
          "token": "a-stream-token"
        }
        """)
        // The two describe one stream and name two different snowflakes. The
        // identify wants the first.
        #expect(created.rtc_channel_id?.rawValue == 1_544_564_589_096_993_916)
        #expect(update.domain?.serverID == "1424759145021837325")
        #expect(String(created.rtc_channel_id?.rawValue ?? 0) != update.domain?.serverID)
    }
}
