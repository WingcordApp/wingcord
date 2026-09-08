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
