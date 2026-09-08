import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

@Suite("Discovery envelopes")
struct DiscoveryEnvelopeTests {

    /// **The one thing here that answers plausible nonsense rather than
    /// failing.** The browse route sends `total` and the search route sends
    /// `total_count`; a decoder written for one and pointed at the other reads
    /// zero and reports "no results" over a full page of them.
    @Test("The browse envelope and the search envelope both decode")
    func bothEnvelopesDecode() throws {
        let browse = Data("""
        {"total": 6459, "offset": 30, "limit": 30, "guilds": [
          {"id":"1193841000111136244","name":"Marvel Rivals","description":"The official server.",
           "icon":"a","banner":"b","splash":"c","discovery_splash":"d",
           "features":["DISCOVERABLE","PREVIEW_ENABLED"],
           "approximate_member_count":4453182,"approximate_presence_count":880686,
           "premium_subscription_count":2580}]}
        """.utf8)
        let page = try JSONDecoder().decode(DiscoverBrowseDTO.self, from: browse).domain
        #expect(page.total == 6459)
        #expect(page.offset == 30)
        #expect(page.guilds.first?.memberCount == 4_453_182)
        #expect(page.guilds.first?.canPreview == true)

        let search = Data("""
        {"total_count": 332, "categories": [{"id":"-1","count":332},{"id":"1","count":281}],
         "guilds": [
          {"id":"1193841000111136244","name":"Marvel Rivals",
           "features":["VERIFIED","DISCOVERABLE"],
           "approximate_member_count":4453180,"approximate_presence_count":1149493}]}
        """.utf8)
        let hits = try JSONDecoder().decode(DiscoverSearchDTO.self, from: search).domain
        #expect(hits.total == 332)
        #expect(hits.counts[1] == 281)
        #expect(hits.counts[DiscoveryPage.allCategoriesFacet] == 332)
        #expect(hits.guilds.first?.name == "Marvel Rivals")
    }

    /// An empty description is what a server with none sends, and it is the same
    /// absence as a missing key — a card must not reserve a line for it twice.
    @Test("An empty description is an absence")
    func emptyDescriptionIsNil() throws {
        let data = Data("""
        {"guilds":[{"id":"1","name":"A","description":"","features":[]}],"total":1}
        """.utf8)
        let page = try JSONDecoder().decode(DiscoverBrowseDTO.self, from: data).domain
        #expect(page.guilds.first?.description == nil)
    }

    /// The facet's id is a string where every other category id on this surface
    /// is an integer. A bucket that will not parse costs one chip, not the facet.
    @Test("A facet bucket that will not parse is dropped")
    func unparsableFacetIsDropped() throws {
        let data = Data("""
        {"total_count":1,"categories":[{"id":"nonsense","count":5},{"id":"3","count":2}],"guilds":[]}
        """.utf8)
        let page = try JSONDecoder().decode(DiscoverSearchDTO.self, from: data).domain
        #expect(page.counts == [3: 2])
    }
}

// MARK: - Notification settings on READY

/// `user_guild_settings`, which is where the reader's own answer to "tell me
/// about this" lives.
///
/// **Three of the five fields here were on the wire and decoded by nothing.**
/// `message_notifications` was read on the channel override and dropped;
/// `suppress_everyone`, `suppress_roles` and the guild-level level were not
/// decoded at all. Every one of them is a reason somebody would either be
/// interrupted or not, so a client that ignored them was making the decision on
/// half the facts.
@Suite("Guild notification settings")
struct GuildNotificationSettingsTests {

    @Test("Every field on a settings entry decodes")
    func settingsDecode() throws {
        let data = Data("""
        {"guild_id":"1000","muted":true,"message_notifications":1,
         "suppress_everyone":true,"suppress_roles":false,
         "channel_overrides":[
           {"channel_id":"2000","muted":false,"message_notifications":0,"flags":0},
           {"channel_id":"2001","muted":true,"message_notifications":2,"flags":0}]}
        """.utf8)
        let dto = try JSONDecoder().decode(GuildSettingsDTO.self, from: data)
        #expect(dto.muted == true)
        #expect(dto.message_notifications == 1)
        #expect(dto.suppress_everyone == true)
        #expect(dto.suppress_roles == false)
        #expect(dto.channel_overrides?.count == 2)
        #expect(dto.channel_overrides?.first?.message_notifications == 0)
    }

    /// A server that has never had its default touched sends `0`, and one that
    /// has sends `1`. **The floor under every decision** — most large servers
    /// set Only @mentions, and a client that assumed All Messages would notify
    /// on every line of a channel with four hundred thousand people in it.
    @Test("A guild carries the default it tells new members")
    func guildDefaultDecodes() throws {
        let quiet = Data("""
        {"id":"1000","name":"Big","default_message_notifications":1}
        """.utf8)
        #expect(
            try JSONDecoder().decode(GuildDTO.self, from: quiet)
                .domain.defaultMessageNotifications == .onlyMentions
        )
        // Absent is Discord's own default, which is all messages.
        let bare = Data("""
        {"id":"1000","name":"Small"}
        """.utf8)
        #expect(
            try JSONDecoder().decode(GuildDTO.self, from: bare)
                .domain.defaultMessageNotifications == .allMessages
        )
    }
}

/// An app's own directory page, and the three fields it carries that the
/// launcher's copy never needed.
///
/// Captured in `blazing 8s.har` and `wordle.har`.
@Suite("App directory page")
struct AppDirectoryPageTests {

    private let payload = Data("""
    {"id":"832025144392635995","name":"Blazing 8s","icon":"a1",
     "description":"A card game.","summary":"",
     "directory_entry":{
       "guild_count":22700,
       "short_description":"Be the first to zero cards.",
       "detailed_description":"__WHAT IS BLAZING 8S?__",
       "supported_locales":["en-US","fr"],
       "external_urls":[{"name":"FAQ","url":"https://support.discord.com/faq"},
                        {"name":"Sneaky","url":"http://insecure.example.invalid"}],
       "carousel_items":[
         {"type":1,"url":"https://a.example.invalid/1.gif","proxy_url":"https://proxy.example.invalid/1.gif"},
         {"type":2,"url":"https://youtube.example.invalid/embed"},
         {"type":1,"url":"https://a.example.invalid/2.png"}]}}
    """.utf8)

    /// **The whole strip, where this used to keep only the first.** The hero is
    /// still that first item; the rest are the gallery Discord pages under the
    /// title, and decoding a list to use one of it is the defect this pins.
    @Test("The carousel decodes whole, pictures only, proxy preferred")
    func galleryDecodes() throws {
        let app = try #require(
            JSONDecoder().decode(DirectoryApplicationDTO.self, from: payload).domain
        )
        // The YouTube embed is filtered: it needs a browser, not an image view.
        #expect(app.gallery.count == 2)
        #expect(app.gallery.first?.host == "proxy.example.invalid")
        #expect(app.heroImageURL == app.gallery.first)
    }

    /// A developer-supplied address, so the scheme is checked at the wire
    /// boundary rather than trusted at the call site.
    @Test("An external link over plain http is dropped")
    func insecureLinkIsDropped() throws {
        let app = try #require(
            JSONDecoder().decode(DirectoryApplicationDTO.self, from: payload).domain
        )
        #expect(app.externalLinks.map(\.name) == ["FAQ"])
    }

    @Test("Supported locales come back as tags and are named for the reader")
    func localesDecode() throws {
        let app = try #require(
            JSONDecoder().decode(DirectoryApplicationDTO.self, from: payload).domain
        )
        #expect(app.supportedLocales == ["en-US", "fr"])
        // Named rather than tagged — the exact wording is the system's.
        #expect(app.languageNames.count == 2)
        #expect(app.languageNames.allSatisfy { !$0.isEmpty })
    }

    @Test("The server count and the two descriptions come off the entry")
    func entryFieldsDecode() throws {
        let app = try #require(
            JSONDecoder().decode(DirectoryApplicationDTO.self, from: payload).domain
        )
        #expect(app.guildCount == 22_700)
        #expect(app.tagline == "Be the first to zero cards.")
    }
}
