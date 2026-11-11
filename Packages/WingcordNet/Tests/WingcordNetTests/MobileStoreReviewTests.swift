import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// The App Store's and Play Store's lines on a game's Reviews card: read as
/// Discord reads them (`reviews.app_store`, `reviews.google_play`) and linked as
/// Discord links them (`n0`, `n2`).
@Suite("Mobile store reviews")
struct MobileStoreReviewTests {

    private func game(_ json: String) throws -> Game {
        try #require(try JSONDecoder().decode([GameDTO].self, from: Data(json.utf8)).first?.domain)
    }

    @Test("Both stores decode, and a page on the store's own host is the link")
    func bothStores() throws {
        let game = try game("""
        [{ "id": "100", "name": "Subway Surfers",
           "reviews": {
             "app_store": { "rating": 4.54, "rating_count": 20565034 },
             "google_play": { "rating": 4.2, "global_rating_count": 53592447 }
           },
           "websites": [
             { "url": "https://apps.apple.com/us/app/subway-surfers/id512939461", "category": 10 },
             { "url": "https://play.google.com/store/apps/details?id=com.kiloo.subwaysurf", "category": 12 }
           ] }]
        """)
        let lines = game.mobileStoreReviews
        #expect(lines.map(\.store) == [.appStore, .googlePlay])
        // In the reader's own numbers, as every count in the app is.
        #expect(lines[0].ratingText == "\(4.5.formatted(.number.precision(.fractionLength(1)))) / 5")
        #expect(lines[0].countText == "(\(20_565_034.formatted(.number)))")
        #expect(lines[0].url.absoluteString == "https://apps.apple.com/us/app/subway-surfers/id512939461")
        // `global_rating_count` stands in for a missing `rating_count`.
        #expect(lines[1].count == 53_592_447)
        #expect(lines[1].ratingText == "\(4.2.formatted(.number.precision(.fractionLength(1)))) / 5")
    }

    @Test("A store's id in the SKUs makes the page when no website names one")
    func pageFromTheSKU() throws {
        let game = try game("""
        [{ "id": "100", "name": "Game",
           "reviews": { "app_store": { "rating": 4, "rating_count": 10 },
                        "google_play": { "rating": 3.9, "rating_count": 11 } },
           "websites": [ { "url": "https://example.com/not-the-store", "category": 10 } ],
           "third_party_skus": [ { "distributor": "apple_app_store", "id": "512939461" },
                                 { "distributor": "google_play", "id": "com.example.game" } ] }]
        """)
        let lines = game.mobileStoreReviews
        #expect(lines.first?.url.absoluteString == "https://apps.apple.com/app/id512939461")
        #expect(lines.last?.url.absoluteString == "https://play.google.com/store/apps/details?id=com.example.game")
    }

    @Test("No page, or no count, is no line")
    func incompleteIsLeftOut() throws {
        let game = try game("""
        [{ "id": "100", "name": "Game",
           "reviews": { "app_store": { "rating": 4.1, "rating_count": 10 },
                        "google_play": { "rating": 4.0 } } }]
        """)
        #expect(game.mobileStoreReviews.isEmpty)
        #expect(game.reviews?.appStore?.count == 10)
        #expect(game.reviews?.googlePlay == nil)
    }
}
