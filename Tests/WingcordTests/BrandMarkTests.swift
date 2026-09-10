import CoreGraphics
import Foundation
import Testing
@testable import Wingcord

/// The connection marks, and the parser that builds them.
///
/// **Every mark is checked, not a sample.** The outlines are a data table: one
/// bad character in one of them produces one silently missing icon, on one
/// service, on one person's profile — which is exactly the kind of defect that
/// ships. Walking all of them costs microseconds and turns that into a build
/// failure.
@Suite("Brand marks")
nonisolated struct BrandMarkTests {

    /// The full set, as Discord names them.
    ///
    /// `nonisolated` on the type, not the property: the test target defaults to
    /// main-actor isolation, and the `arguments:` list is read by the macro from
    /// outside any actor.
    private static let services = [
        "battlenet", "bluesky", "bungie", "crunchyroll", "ebay", "epicgames",
        "facebook", "github", "instagram", "leagueoflegends", "mastodon",
        "paypal", "playstation", "reddit", "riotgames", "roblox", "skype",
        "spotify", "steam", "tiktok", "twitch", "twitter", "xbox", "youtube",
    ]

    @Test("Every mark parses", arguments: services)
    func parses(service: String) throws {
        let path = try #require(
            BrandMark.path(for: service),
            "\(service) has no parsable outline"
        )
        #expect(!path.isEmpty)
    }

    /// A path that parses can still be nonsense — a dropped decimal point puts a
    /// coordinate an order of magnitude out and the mark becomes a scribble the
    /// size of a wall. The authored grid is the check on that.
    @Test("Every mark stays on the 24-unit grid", arguments: services)
    func fitsTheGrid(service: String) throws {
        let path = try #require(BrandMark.path(for: service))
        // The TIGHT box. `boundingBox` includes off-curve control points, which
        // legitimately sit outside the artwork.
        let box = path.boundingBoxOfPath
        #expect(box.minX >= -0.01)
        #expect(box.minY >= -0.01)
        #expect(box.maxX <= BrandMark.side + 0.01)
        #expect(box.maxY <= BrandMark.side + 0.01)
        // And it fills a fair share of it: a mark collapsed to a dot also fits.
        let smallestSide = min(box.width, box.height)
        #expect(smallestSide > 8)
    }

    @Test("Every mark names its brand and picks a legible glyph", arguments: services)
    func hasBrand(service: String) throws {
        let mark = try #require(BrandMark.mark(for: service))
        #expect(!mark.name.isEmpty)
        // Not an assertion about which answer is right — only that the decision
        // is made from the colour rather than defaulting for everyone, which a
        // luminance function that always returned the same value would.
        _ = BrandMark.prefersLightGlyph(on: mark.tint)
    }

    @Test("A brand's own black plate takes a white glyph")
    func darkPlatesTakeWhite() {
        #expect(BrandMark.prefersLightGlyph(on: 0x000000))
        #expect(BrandMark.prefersLightGlyph(on: 0x181717))   // GitHub
        #expect(!BrandMark.prefersLightGlyph(on: 0xFFFFFF))
    }

    @Test("Discord's staging PlayStation resolves to the same brand")
    func stagingAlias() {
        #expect(BrandMark.mark(for: "playstation-stg")?.name == "PlayStation")
    }

    @Test("A service with no mark answers nil rather than an empty path")
    func unknownService() {
        #expect(BrandMark.mark(for: "domain") == nil)
        #expect(BrandMark.path(for: "domain") == nil)
        #expect(BrandMark.path(for: "something-discord-added-later") == nil)
    }

    @Test("Malformed outlines are rejected, never half-built")
    func malformed() {
        // A path that is half-parsed is worse than none, because it draws.
        #expect(VectorPath.parse("") == nil)
        #expect(VectorPath.parse("L1 1") == nil)           // a line before a move
        #expect(VectorPath.parse("M1") == nil)             // a point with one number
        #expect(VectorPath.parse("M0 0 C1 1 2 2") == nil)  // a curve missing its end
        #expect(VectorPath.parse("M0 0 Q1 1 2 2") == nil)  // a command with no case
    }

    @Test("A well-formed outline builds the shape it describes")
    func wellFormed() throws {
        let path = try #require(VectorPath.parse("M0 0 L10 0 L10 5 Z"))
        let box = path.boundingBoxOfPath
        #expect(box.width == 10)
        #expect(box.height == 5)
    }
    // MARK: Colour, as ground and as ink

    /// **Two tests over the same luminance, and confusing them put a pink tile
    /// behind Nitro on the profile's date line.**
    ///
    /// `prefersLightGlyph` answers "which glyph reads *on* this colour" — the
    /// question the connection dock asks, where the brand colour is the ground.
    /// `readsAsInk` answers "does this colour read *on the card*" — the question
    /// a bare mark asks. Nitro at 0.404 is bright enough for both: it wants a
    /// dark glyph laid on it, and it is perfectly legible as ink with nothing
    /// under it at all. The plate was never about legibility here.
    @Test("Nitro is bright enough to be ink, and to take a dark glyph on it")
    func nitroReadsBothWays() throws {
        let nitro = try #require(BrandMark.mark(for: BrandMark.nitro))
        #expect(BrandMark.readsAsInk(nitro.tint))
        #expect(!BrandMark.prefersLightGlyph(on: nitro.tint))
    }

    /// Blurple is dim and saturated — exactly the shape of colour the ink floor
    /// must not reject, since Discord sets type in it on dark surfaces itself.
    @Test("A dim but saturated brand still reads as ink")
    func blurpleIsInk() throws {
        let discord = try #require(BrandMark.mark(for: BrandMark.discord))
        #expect(BrandMark.readsAsInk(discord.tint))
    }

    /// **What the floor exists to reject.** Four brands in this table are black,
    /// and bare ink in their colour on this app's near-black card is an empty
    /// square — those are the ones that still need a plate.
    @Test("Black is not ink")
    func blackIsNotInk() {
        #expect(!BrandMark.readsAsInk(0x000000))
        #expect(!BrandMark.readsAsInk(0x0A0A0C))
        #expect(BrandMark.readsAsInk(0xFFFFFF))
    }

    /// **The connection dock's own premise, checked.** Its doc says the colour
    /// has to be the ground because several of these brands are black — so at
    /// least one of them must actually fail the ink floor, or the plate is
    /// solving a problem the table does not have.
    @Test("Some brands really are too dark to be ink, which is why the plate exists")
    func someBrandsNeedThePlate() {
        let tooDark = Self.services
            .compactMap(BrandMark.mark(for:))
            .filter { !BrandMark.readsAsInk($0.tint) }
        #expect(!tooDark.isEmpty)
    }

}
