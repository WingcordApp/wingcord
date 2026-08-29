import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// Decoding a collectible product into something drawable.
///
/// **One route, two shapes, and that is the point of these tests.**
/// `GET /collectibles-products/{sku}` answers for a profile effect and for a
/// profile frame, and the two payloads share almost nothing: an effect carries
/// an `effects` timeline with `src` URLs, a frame carries `layers` with ids and
/// no URL at all. A decoder written for the first returns nothing for the
/// second — not an error, just nothing — which is exactly how a frame somebody
/// is wearing stays invisible while every request succeeds.
///
/// Both fixtures are **real responses**, captured live and trimmed only of the
/// store fields this client does not read. They are here verbatim because the
/// things most likely to be wrong about them are invisible to a hand-written
/// fixture: the effect timings are in **milliseconds**, the effect keys are
/// **camelCase inside an otherwise snake_case API**, and the frame's keys in
/// that same object are snake_case again.
struct CollectiblesProductTests {

    /// Kawaii Clouds: an intro that plays once, then a loop, back to back.
    private static let effectJSON = """
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
           "height":880,"width":450,"duration":3000,"start":0,"loopDelay":0,
           "position":{"x":0,"y":0},"zIndex":100,"randomizedSources":[]},
          {"src":"https://cdn.discordapp.com/assets/content/loop","loop":true,
           "height":880,"width":450,"duration":3000,"start":3000,"loopDelay":0,
           "position":{"x":0,"y":0},"zIndex":101,"randomizedSources":[]}
        ]
      }],
      "type": 1
    }
    """

    /// Nevermore (White), which is the reason `loopDelay` is read at all: its
    /// loop runs three seconds and then waits four, so its birds cross a card
    /// every seven. Read without the delay they fly continuously.
    private static let delayedEffectJSON = """
    {
      "sku_id": "1462116613775167569",
      "name": "Nevermore (White)",
      "items": [{
        "type": 1,
        "sku_id": "1462116613775167569",
        "title": "Nevermore (White)",
        "accessibilityLabel": "Gray birds fly across a misty background while feathers fall.",
        "animationType": 2,
        "reducedMotionSrc": "https://cdn.discordapp.com/assets/content/reduced",
        "effects": [
          {"src":"https://cdn.discordapp.com/assets/content/intro","loop":false,
           "height":880,"width":450,"duration":3000,"start":0,"loopDelay":0,
           "position":{"x":0,"y":0},"zIndex":100,"randomizedSources":[]},
          {"src":"https://cdn.discordapp.com/assets/content/loop","loop":true,
           "height":880,"width":450,"duration":3000,"start":4400,"loopDelay":4000,
           "position":{"x":0,"y":0},"zIndex":101,"randomizedSources":[]}
        ]
      }],
      "type": 1
    }
    """

    /// Dark Roses (Blue): a frame, `type: 3`, with no `src` anywhere in it.
    private static let frameJSON = """
    {
      "sku_id": "1515124557290410204",
      "name": "Dark Roses (Blue)",
      "summary": "Elevate and wrap your profile with a frame.",
      "items": [{
        "type": 3,
        "sku_id": "1515124557290410204",
        "label": "Blue roses sit on the top left and bottom right corners of the profile and climb up the sides",
        "layers": [
          {"id":"1515124885113012234","type":"staple","order":"front","anchor":"top","responsive":false},
          {"id":"1515124888313266236","type":"staple","order":"front","anchor":"bottom","responsive":false}
        ],
        "inner_width": 1200,
        "overflow_top": 211,
        "overflow_bottom": 186,
        "overflow_horizontal": 56
      }],
      "type": 3
    }
    """

    private enum Shape: Error { case notAnEffect, notAFrame }

    private func product(_ json: String) throws -> Collectible {
        let dto = try JSONDecoder().decode(
            CollectiblesProductDTO.self, from: Data(json.utf8)
        )
        return try #require(dto.domain)
    }

    private func effect(_ json: String = effectJSON) throws -> ProfileEffect {
        guard case .effect(let effect) = try product(json) else { throw Shape.notAnEffect }
        return effect
    }

    private func frame() throws -> ProfileFrame {
        guard case .frame(let frame) = try product(Self.frameJSON) else { throw Shape.notAFrame }
        return frame
    }

    // MARK: Profile effects

    @Test("Both layers survive, in paint order")
    func decodesLayers() throws {
        let effect = try effect()
        #expect(effect.skuID == "1402472280354116086")
        #expect(effect.title == "Kawaii Clouds")
        #expect(effect.layers.count == 2)
        #expect(effect.layers.map(\.zIndex) == [100, 101])
    }

    @Test("Milliseconds become seconds")
    func convertsTiming() throws {
        // Read as seconds, each layer would last most of an hour and the loop
        // would not begin until the card had been open for fifty minutes.
        let effect = try effect()
        #expect(effect.layers[0].start == 0)
        #expect(effect.layers[0].duration == 3)
        #expect(effect.layers[1].start == 3)
        #expect(effect.layers[1].duration == 3)
    }

    @Test("Loop flags are carried, not defaulted")
    func carriesLoopFlags() throws {
        let effect = try effect()
        #expect(effect.layers[0].loops == false)
        #expect(effect.layers[1].loops == true)
        #expect(effect.loopsForever)
    }

    @Test("The gap between passes is carried, and in seconds")
    func carriesLoopDelay() throws {
        // Dropped, Nevermore's birds fly every three seconds instead of every
        // seven — the loop restarting the instant it ends. The default is zero
        // and most effects send zero, which is why this is invisible until an
        // effect that uses it turns up.
        let effect = try effect(Self.delayedEffectJSON)
        #expect(effect.layers[1].loopDelay == 4)
        #expect(effect.layers[1].start == 4.4)
    }

    @Test("The reduced-motion still and the label are picked up")
    func carriesAccessibility() throws {
        let effect = try effect()
        #expect(effect.reducedMotionURL?.lastPathComponent == "reduced")
        #expect(effect.accessibilityLabel?.hasPrefix("Pink clouds") == true)
    }

    // MARK: Profile frames

    @Test("A frame decodes as a frame, not as an empty effect")
    func decodesFrame() throws {
        let frame = try frame()
        #expect(frame.skuID == "1515124557290410204")
        #expect(frame.frontLayers.count == 2)
        #expect(frame.backLayers.isEmpty)
        #expect(frame.label?.hasPrefix("Blue roses") == true)
    }

    @Test("Each layer knows the edge it hangs from")
    func carriesAnchors() throws {
        let frame = try frame()
        #expect(frame.frontLayers.map(\.anchor) == [.top, .bottom])
        #expect(frame.frontLayers.allSatisfy { $0.order == .front })
    }

    @Test("Layer artwork is addressed by layer id under the product's SKU")
    func buildsLayerURLs() throws {
        // The payload carries no `src` for a frame at ALL — only ids — so this
        // template is the whole of how a frame becomes pictures. Verified
        // against the live CDN: `static` answers 200 and `animated`, `asset`
        // and `preview` all 404, which is why a frame needs no clock.
        let frame = try frame()
        #expect(
            frame.frontLayers[0].url.absoluteString
                == "https://cdn.discordapp.com/media/v1/collectibles-shop/1515124557290410204/1515124885113012234/static"
        )
    }

    @Test("The overflow numbers survive, and they describe the artwork's own width")
    func carriesOverflow() throws {
        let frame = try frame()
        #expect(frame.innerWidth == 1200)
        #expect(frame.overflowTop == 211)
        #expect(frame.overflowBottom == 186)
        #expect(frame.overflowHorizontal == 56)
        // **The relationship the whole layout rests on.** Both of this frame's
        // layer PNGs are exactly 1312 pixels wide, which is this sum — so the
        // artwork is authored in the same coordinate space as these numbers and
        // one scale factor places all of it. A payload where that did not hold
        // would need the layer's own size, which the payload does not send.
        #expect(frame.innerWidth + frame.overflowHorizontal * 2 == 1312)
    }

    @Test("A product with neither shape is nothing, rather than an empty one")
    func emptyProductIsNil() throws {
        let empty = #"{"sku_id":"1","name":"x","items":[{"sku_id":"1","effects":[],"layers":[]}]}"#
        let dto = try JSONDecoder().decode(
            CollectiblesProductDTO.self, from: Data(empty.utf8)
        )
        #expect(dto.domain == nil)
    }

    @Test("A frame with layers but no authored width is not drawable")
    func frameWithoutInnerWidthIsNil() throws {
        // Every number in a frame's layout is a fraction of `inner_width`.
        // Without it there is no scale, and a frame drawn at an assumed one is
        // a garland the wrong size on every card.
        let json = #"""
        {"sku_id":"1","name":"x","items":[{"sku_id":"1",
         "layers":[{"id":"9","order":"front","anchor":"top"}]}]}
        """#
        let dto = try JSONDecoder().decode(
            CollectiblesProductDTO.self, from: Data(json.utf8)
        )
        #expect(dto.domain == nil)
    }

    @Test("An unrecognised anchor or order costs one picture, not the frame")
    func unknownVocabularyFallsBack() throws {
        let json = #"""
        {"sku_id":"1","name":"x","items":[{"sku_id":"1","inner_width":1200,
         "layers":[{"id":"9","order":"sideways","anchor":"middle"}]}]}
        """#
        let dto = try JSONDecoder().decode(
            CollectiblesProductDTO.self, from: Data(json.utf8)
        )
        guard case .frame(let frame) = try #require(dto.domain) else {
            throw Shape.notAFrame
        }
        #expect(frame.frontLayers.count == 1)
        #expect(frame.frontLayers[0].anchor == .top)
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

/// Kawaii Cat, captured live — the frame that exposed the third anchor.
///
/// Its `type: "border"` layer is anchored `center` and is 1312x2528, far taller
/// than any card. Falling that back to `.top` and fitting it drew two pale rails
/// down the middle of the card and past both its ends.
@Suite("Profile frame anchors")
struct ProfileFrameAnchorTests {

    private let kawaiiCat = """
    {"sku_id":"1489396533643448380","name":"Kawaii Cat","type":3,
     "items":[{"type":3,"sku_id":"1489396533643448380","label":"A soft pink border",
       "layers":[
         {"id":"1511832450052133044","type":"border","order":"front","anchor":"center","responsive":false},
         {"id":"1511832453369827559","type":"staple","order":"front","anchor":"top","responsive":false},
         {"id":"1511832456381071471","type":"staple","order":"front","anchor":"bottom","responsive":false}],
       "inner_width":1200,"overflow_top":304,"overflow_bottom":135,"overflow_horizontal":56}]}
    """

    @Test("A centre-anchored border decodes as itself, not as a top staple")
    func centerAnchorDecodes() throws {
        let dto = try #require(
            try? JSONDecoder().decode(CollectiblesProductDTO.self, from: Data(kawaiiCat.utf8))
        )
        guard case .frame(let frame)? = dto.domain else {
            Issue.record("expected a frame"); return
        }
        #expect(frame.frontLayers.count == 3)
        #expect(frame.frontLayers.map(\.anchor) == [.center, .top, .bottom])
        #expect(frame.innerWidth == 1200)
        #expect(frame.overflowTop == 304)
        #expect(frame.overflowBottom == 135)
        #expect(frame.overflowHorizontal == 56)
    }

    /// Every layer of every captured frame is authored at `inner_width` plus
    /// both horizontal overflows, which is the one scale the whole composition
    /// shares. Kawaii Cat's three PNGs are all 1312 wide, as Dark Roses' two are.
    @Test("The layout puts every layer at the authored width")
    func authoredWidth() throws {
        let dto = try #require(
            try? JSONDecoder().decode(CollectiblesProductDTO.self, from: Data(kawaiiCat.utf8))
        )
        guard case .frame(let frame)? = dto.domain else {
            Issue.record("expected a frame"); return
        }
        let layout = frame.layout(cardWidth: 1200)
        #expect(layout.scale == 1)
        #expect(layout.layerWidth == 1312)
        #expect(layout.top == 304)
        #expect(layout.bottom == 135)
    }

    /// An anchor this build has never seen still has to draw something.
    @Test("An unknown anchor falls back rather than failing the frame")
    func unknownAnchorFallsBack() throws {
        let json = kawaiiCat.replacingOccurrences(of: "\"center\"", with: "\"sideways\"")
        let dto = try #require(
            try? JSONDecoder().decode(CollectiblesProductDTO.self, from: Data(json.utf8))
        )
        guard case .frame(let frame)? = dto.domain else {
            Issue.record("expected a frame"); return
        }
        #expect(frame.frontLayers.count == 3)
        #expect(frame.frontLayers[0].anchor == .top)
    }
}
