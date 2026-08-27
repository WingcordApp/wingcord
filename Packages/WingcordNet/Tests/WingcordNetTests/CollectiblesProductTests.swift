import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// Decoding a collectible product into a playable effect.
///
/// The fixture is a **real response**, captured from
/// `GET /collectibles-products/{sku}` for Kawaii Clouds and trimmed only of the
/// store fields this client does not read. It is here verbatim because the two
/// things most likely to be wrong about this payload are invisible to a
/// hand-written fixture: the timing is in **milliseconds**, and the keys that
/// matter are **camelCase** inside an otherwise snake_case API.
struct CollectiblesProductTests {

    private static let json = """
    {
      "sku_id": "1402472280354116086",
      "name": "Kawaii Clouds",
      "items": [{
        "type": 1,
        "sku_id": "1402472280354116086",
        "title": "Kawaii Clouds",
        "accessibilityLabel": "Pink clouds, blue and green chains, twinkling stars, and soft sparkles.",
        "animationType": 1,
        "staticFrameSrc": "https://cdn.discordapp.com/assets/content/static",
        "reducedMotionSrc": "https://cdn.discordapp.com/assets/content/reduced",
        "effects": [
          {"src":"https://cdn.discordapp.com/assets/content/intro","loop":false,
           "height":880,"width":450,"duration":3000,"start":0,"zIndex":100},
          {"src":"https://cdn.discordapp.com/assets/content/loop","loop":true,
           "height":880,"width":450,"duration":3000,"start":3000,"zIndex":101}
        ]
      }],
      "type": 1
    }
    """

    private func decode() throws -> ProfileEffect {
        let dto = try JSONDecoder().decode(
            CollectiblesProductDTO.self, from: Data(Self.json.utf8)
        )
        return try #require(dto.domain)
    }

    @Test("Both layers survive, in paint order")
    func decodesLayers() throws {
        let effect = try decode()
        #expect(effect.skuID == "1402472280354116086")
        #expect(effect.title == "Kawaii Clouds")
        #expect(effect.layers.count == 2)
        #expect(effect.layers.map(\.zIndex) == [100, 101])
    }

    @Test("Milliseconds become seconds")
    func convertsTiming() throws {
        // Read as seconds, each layer would last most of an hour and the loop
        // would not begin until the card had been open for fifty minutes.
        let effect = try decode()
        #expect(effect.layers[0].start == 0)
        #expect(effect.layers[0].duration == 3)
        #expect(effect.layers[1].start == 3)
        #expect(effect.layers[1].duration == 3)
    }

    @Test("Loop flags are carried, not defaulted")
    func carriesLoopFlags() throws {
        let effect = try decode()
        #expect(effect.layers[0].loops == false)
        #expect(effect.layers[1].loops == true)
        #expect(effect.loopsForever)
    }

    @Test("The reduced-motion still and the label are picked up")
    func carriesAccessibility() throws {
        let effect = try decode()
        #expect(effect.reducedMotionURL?.lastPathComponent == "reduced")
        #expect(effect.accessibilityLabel?.hasPrefix("Pink clouds") == true)
    }

    @Test("A product with no effects is not an effect")
    func emptyProductIsNil() throws {
        let empty = #"{"sku_id":"1","name":"x","items":[{"sku_id":"1","effects":[]}]}"#
        let dto = try JSONDecoder().decode(
            CollectiblesProductDTO.self, from: Data(empty.utf8)
        )
        #expect(dto.domain == nil)
    }

    /// The mutual servers arrive as a list and are kept as one.
    ///
    /// They used to be counted on the way in and the list thrown away, which
    /// made "1 Mutual Server" a line the reader had to go and check elsewhere.
    /// The count is now derived from what is kept, so the label and the list it
    /// opens cannot disagree — including about an entry with no id, which is
    /// dropped from both rather than counted in one.
    @Test("Mutual servers survive the decode, and a nameless one is dropped")
    func keepsMutualGuilds() throws {
        let json = #"""
        {"user":{"id":"1","username":"a"},
         "mutual_guilds":[{"id":"41","nick":"Ali"},{"id":"42"},{"nick":"orphan"},{"id":"43","nick":""}]}
        """#
        let dto = try JSONDecoder().decode(UserProfileDTO.self, from: Data(json.utf8))
        let decoration = try #require(dto.domain.decoration)
        #expect(decoration.mutualGuilds.count == 3)
        #expect(decoration.mutualGuilds[0].nickname == "Ali")
        // Sent, but empty. An empty nickname is not a nickname, and drawing one
        // reserves a second line under the server's name for nothing.
        #expect(decoration.mutualGuilds[1].nickname == nil)
        #expect(decoration.mutualGuilds[2].nickname == nil)
    }

    @Test("Discord's fractional-second timestamps parse")
    func parsesFractionalDates() throws {
        // `2026-07-28T22:06:12.878000+00:00` — the default ISO-8601 strategy
        // rejects the fraction, which would silently nil every Nitro date.
        let json = #"{"user":{"id":"1","username":"a"},"premium_since":"2026-07-28T22:06:12.878000+00:00","premium_type":2}"#
        let dto = try JSONDecoder().decode(UserProfileDTO.self, from: Data(json.utf8))
        let decoration = try #require(dto.domain.decoration)
        #expect(decoration.premiumSince != nil)
        #expect(decoration.premiumTier == .nitro)
    }
}
