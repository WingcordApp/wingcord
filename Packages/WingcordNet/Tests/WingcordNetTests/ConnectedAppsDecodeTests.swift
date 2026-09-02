import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// `GET /users/@me/connections` and `GET /oauth2/tokens`.
///
/// Every payload below is captured, trimmed only of the fields neither route's
/// pane reads. Both routes are undocumented, and a decoder written against a
/// shape somebody remembered does not fail loudly — it yields a page that is
/// confidently wrong.
@Suite("Connected apps")
struct ConnectedAppsDecodeTests {

    // MARK: Connections

    /// Two Spotify accounts, one visible on profile and one not — and the
    /// phantom `"contacts"` entry every capture of this route carries beside
    /// the reader's real connections.
    private let connectionsList = """
    [
      {"id":"@me","name":"","type":"contacts","friend_sync":false,
       "integrations":[],"metadata_visibility":1,"show_activity":true,
       "two_way_link":false,"verified":false,"visibility":0,"revoked":false},
      {"id":"31lktbiw5supkek5lw5fzysjsnzy","name":"dudcalled_dusk","type":"spotify",
       "friend_sync":false,"integrations":[],"metadata_visibility":1,
       "show_activity":true,"two_way_link":false,"verified":true,"visibility":0,
       "revoked":false,"access_token":"BQBMW1BX"},
      {"id":"914dvjzfdcmqfrovtvoazinrg","name":"alex","type":"spotify",
       "friend_sync":false,"integrations":[],"metadata_visibility":1,
       "show_activity":true,"two_way_link":false,"verified":true,"visibility":1,
       "revoked":false,"access_token":"BQCCUEL7"}
    ]
    """

    private func connections(_ json: String) throws -> [AccountConnection] {
        try JSONDecoder().decode([ConnectionDTO].self, from: Data(json.utf8)).compactMap(\.domain)
    }

    @Test("The contacts entry is dropped, not decoded as a platform")
    func contactsIsDropped() throws {
        let list = try connections(connectionsList)
        #expect(list.count == 2)
        #expect(list.allSatisfy { $0.type != "contacts" })
    }

    @Test("visibility 0 and 1 become false and true")
    func visibilityDecodesAsBool() throws {
        let list = try connections(connectionsList)
        let dusk = try #require(list.first { $0.name == "dudcalled_dusk" })
        let alex = try #require(list.first { $0.name == "alex" })
        #expect(dusk.isVisibleOnProfile == false)
        #expect(alex.isVisibleOnProfile == true)
        #expect(dusk.showsActivity == true)
    }

    /// The `PATCH` response for "Display on profile", captured right after
    /// the request that flips it. The request body sends `{"visibility":true}`
    /// — a `Bool` — and this is what comes back: the same field as an `Int`.
    private let patchVisibilityResponse = """
    {"type":"spotify","id":"31lktbiw5supkek5lw5fzysjsnzy","name":"dudcalled_dusk",
     "visibility":1,"friend_sync":false,"show_activity":true,"verified":true,
     "two_way_link":false,"metadata_visibility":1,"revoked":false}
    """

    @Test("The PATCH response decodes the same as a GET row")
    func patchResponseDecodes() throws {
        let dto = try JSONDecoder().decode(ConnectionDTO.self, from: Data(patchVisibilityResponse.utf8))
        let connection = try #require(dto.domain)
        #expect(connection.isVisibleOnProfile == true)
        #expect(connection.type == "spotify")
    }

    // MARK: Authorized apps

    /// Watch Together's own entry, captured the moment before it was
    /// deauthorized — trimmed of the bot user, install params and integration
    /// config this pane never reads.
    private let watchTogether = """
    {"id":"1544745494572235463",
     "scopes":["guilds","identify","applications.commands","guilds.members.read","rpc.activities.write"],
     "application":{
       "id":"880218394199220334","name":"Watch Together",
       "icon":"ec48acbad4c32efab4275cb9f3ca3a58",
       "description":"Create and watch shared playlists of YouTube videos with your friends. Your choice to share the remote or not. ",
       "is_verified":true
     }}
    """

    @Test("An authorized app decodes its grant id, application and scopes")
    func authorizedAppDecodes() throws {
        let dto = try JSONDecoder().decode(AuthorizedAppDTO.self, from: Data(watchTogether.utf8))
        let app = try #require(dto.domain)
        #expect(app.name == "Watch Together")
        #expect(app.applicationID == ApplicationID(rawValue: 880_218_394_199_220_334))
        #expect(app.scopes == ["guilds", "identify", "applications.commands", "guilds.members.read", "rpc.activities.write"])
        #expect(app.isVerified)
    }

    /// **There is no date field anywhere in this payload.** Discord's own
    /// settings window showed "Authorized on 9/2/2026" for this exact grant;
    /// the only place that date can come from is the snowflake in `id`.
    @Test("The grant id's own timestamp is the authorization date")
    func authorizedAtComesFromTheSnowflake() throws {
        let dto = try JSONDecoder().decode(AuthorizedAppDTO.self, from: Data(watchTogether.utf8))
        let app = try #require(dto.domain)
        let components = Calendar(identifier: .gregorian).dateComponents(
            in: TimeZone(identifier: "UTC")!,
            from: app.authorizedAt
        )
        #expect(components.year == 2026)
        #expect(components.month == 9)
        #expect(components.day == 2)
    }

    @Test("A scope this table has never named still reads as something")
    func unknownScopeHumanizes() {
        #expect(OAuthScope.description("some.new.scope") == "Uses its “some.new.scope” permission")
        #expect(OAuthScope.description("rpc.activities.write") == "Set your current activity")
    }
}
