import Foundation
import Testing
@testable import WingcordCore

/// The Rich Presence builder's presence: Vencord's CustomRPC rules and the
/// activity its `createActivity` sends.
struct CustomPresenceTests {
    private let now = Date(timeIntervalSince1970: 1_790_856_000)
    private let appID = "1234567890104688129"

    @Test("A name is all a presence needs, and Vencord's words say what is wrong")
    func rules() {
        var presence = CustomPresence()
        #expect(presence.problem(.name) == "This field is required.")
        #expect(!presence.isPublishable)
        presence.name = "Hollow Knight"
        #expect(presence.isPublishable)

        presence.applicationID = "12ab"
        #expect(presence.problem(.applicationID) == "Must be a valid Discord ID.")
        presence.applicationID = appID
        #expect(presence.problem(.applicationID) == nil)

        presence.details = String(repeating: "a", count: 129)
        #expect(presence.problem(.details) == "Must be not longer than 128 characters.")
        presence.details = ""
        presence.detailsLink = "example.com"
        #expect(presence.problem(.detailsLink) == "Must be a valid URL.")
        presence.detailsLink = "https://example.com"
        #expect(presence.problem(.detailsLink) == nil)

        presence.buttons[0].label = String(repeating: "b", count: 32)
        #expect(presence.problem(.buttonLabel(0)) == "Must be not longer than 31 characters.")
        presence.buttons[0].label = ""

        presence.largeArt.image = "https://cdn.discordapp.com/attachments/1/2/a.png"
        #expect(presence.problem(.largeImage) == "Don't use a Discord link. Use an Imgur image link instead.")
        presence.largeArt.image = "https://imgur.com/abc"
        #expect(presence.problem(.largeImage)?.hasPrefix("Imgur link must be a direct link") == true)
        presence.largeArt.image = "https://i.imgur.com/abc.png"
        #expect(presence.problem(.largeImage) == nil)

        presence.partySize = "-1"
        #expect(presence.problem(.partySize) == "Must be a positive number.")
        presence.partySize = "two"
        #expect(presence.problem(.partySize) == "Must be a number.")
    }

    @Test("The stream link is checked only while Streaming")
    func streamLink() {
        var presence = CustomPresence()
        presence.name = "Live"
        presence.streamLink = "https://example.com"
        #expect(presence.problem(.streamLink) == nil)
        presence.kind = .streaming
        #expect(presence.problem(.streamLink) == "Streaming link must be a valid URL.")
        presence.streamLink = "https://www.twitch.tv/somebody"
        #expect(presence.problem(.streamLink) == nil)
    }

    @Test("The bare presence is Vencord's: the name, Playing, application 0 and INSTANCE")
    func bare() throws {
        var presence = CustomPresence()
        presence.name = "Hollow Knight"
        let activity = try #require(presence.activity(assets: [:], turnedOnAt: now, now: now))
        #expect(activity.type == 0)
        #expect(activity.name == "Hollow Knight")
        #expect(activity.applicationID == ApplicationID(rawValue: 0))
        #expect(activity.flags == 1)
        #expect(activity.details == nil && activity.state == nil && activity.assets == nil)
        #expect(activity.timestamps == nil && activity.party == nil && activity.buttons.isEmpty)
    }

    @Test("Every field goes where Vencord puts it")
    func full() throws {
        var presence = CustomPresence()
        presence.applicationID = appID
        presence.name = "Hollow Knight"
        presence.details = "Greenpath"
        presence.detailsLink = "https://example.com/d"
        presence.state = "Steel Soul"
        presence.largeArt = .init(image: "https://i.imgur.com/a.png", text: "The Knight", link: "https://example.com/l")
        presence.smallArt = .init(image: "badge", text: "Badge")
        presence.buttons = [.init(label: "Wiki", link: "https://example.com/w"), .init(label: "No link")]
        presence.partySize = "1"
        presence.partyMax = "4"
        presence.timer = .sinceOn
        let turnedOn = now.addingTimeInterval(-600)
        let activity = try #require(presence.activity(
            assets: ["https://i.imgur.com/a.png": "mp:external/abc", "badge": "999"],
            turnedOnAt: turnedOn, now: now
        ))
        #expect(activity.applicationID == ApplicationID(rawValue: 1_234_567_890_104_688_129))
        #expect(activity.details == "Greenpath")
        #expect(activity.detailsURL == URL(string: "https://example.com/d"))
        #expect(activity.state == "Steel Soul")
        #expect(activity.assets?.largeImage == "mp:external/abc")
        #expect(activity.assets?.largeText == "The Knight")
        #expect(activity.assets?.largeURL == URL(string: "https://example.com/l"))
        #expect(activity.assets?.smallImage == "999")
        // A button without a link is not sent.
        #expect(activity.buttons == ["Wiki"])
        #expect(activity.buttonURLs == [URL(string: "https://example.com/w")!])
        #expect(activity.party?.size == [1, 4])
        #expect(activity.timestamps?.start == Int(turnedOn.timeIntervalSince1970 * 1000))
    }

    /// Pictures go through the application.
    @Test("Without an application ID there are no pictures")
    func noArtWithoutApplication() throws {
        var presence = CustomPresence()
        presence.name = "Text only"
        presence.largeArt.image = "https://i.imgur.com/a.png"
        #expect(!presence.carriesArt)
        let activity = try #require(presence.activity(
            assets: ["https://i.imgur.com/a.png": "mp:external/abc"], turnedOnAt: now, now: now
        ))
        #expect(activity.assets == nil)
    }

    @Test("Streaming carries its link, and a party is Playing's only")
    func streamingAndParty() throws {
        var presence = CustomPresence()
        presence.name = "Live"
        presence.kind = .streaming
        presence.streamLink = "https://www.twitch.tv/somebody"
        presence.partySize = "1"
        presence.partyMax = "4"
        let activity = try #require(presence.activity(assets: [:], turnedOnAt: now, now: now))
        #expect(activity.type == 1)
        #expect(activity.url == URL(string: "https://www.twitch.tv/somebody"))
        #expect(activity.party == nil)
    }

    @Test("Local time starts at midnight, and Custom takes its own")
    func timers() throws {
        var presence = CustomPresence()
        presence.name = "Clock"
        presence.timer = .localTime
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let midnight = calendar.startOfDay(for: now)
        #expect(presence.activity(assets: [:], turnedOnAt: now, now: now, calendar: calendar)?.timestamps?.start
            == Int(midnight.timeIntervalSince1970 * 1000))
        let end = now.addingTimeInterval(3_600)
        presence.timer = .custom(start: nil, end: end)
        let custom = try #require(presence.activity(assets: [:], turnedOnAt: now, now: now)?.timestamps)
        #expect(custom.start == nil)
        #expect(custom.end == Int(end.timeIntervalSince1970 * 1000))
    }

    @Test("A saved presence comes back as it went")
    func codable() throws {
        var presence = CustomPresence()
        presence.name = "Saved"
        presence.timer = .custom(start: now, end: nil)
        presence.buttons[1] = .init(label: "Two", link: "https://example.com")
        let data = try JSONEncoder().encode([presence])
        #expect(try JSONDecoder().decode([CustomPresence].self, from: data) == [presence])
    }
}
