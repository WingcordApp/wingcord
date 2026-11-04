import AppKit
import Foundation
import SwiftUI
import Testing
import WingcordCore
@testable import Wingcord

/// One card for a badge, whatever has been heard so far.
///
/// **The fight these pin:** a Nitro badge used to raise one card before the
/// directory answered and another after, and the two swapped under the pointer.
@MainActor
@Suite("A badge's card")
struct BadgeCardContentTests {

    private let film = URL(string: "https://cdn.discordapp.com/assets/content/film.png")
    private let directoryStill = URL(string: "https://cdn.discordapp.com/assets/content/still.svg")

    private func gold() throws -> PremiumTenure {
        try #require(PremiumTenure.named("premium_tenure_6_month_v2"))
    }

    private func date() throws -> Date {
        var parts = DateComponents()
        parts.year = 2026
        parts.month = 3
        parts.day = 2
        return try #require(Calendar(identifier: .gregorian).date(from: parts))
    }

    private func directoryEntry() -> CatalogBadge {
        CatalogBadge(
            badgeID: BadgeKind.premiumTenure.rawValue, name: "Nitro", isOwned: true, currentTierKey: "gold",
            tiers: [BadgeTier(key: "gold", name: "Gold", complexIconURL: directoryStill, complexIconAnimatedURL: film)],
            infoLabel: "Subscriber since 3/2/26"
        )
    }

    private func content(
        badge: CatalogBadge? = nil,
        tenure: PremiumTenure? = nil,
        since: Date? = nil,
        label: String = "A label",
        iconURL: URL? = nil,
        reducesMotion: Bool = false
    ) -> BadgeCardContent {
        BadgeCardContent(
            badge: badge, tenure: tenure, premiumSince: since,
            label: label, iconURL: iconURL, reducesMotion: reducesMotion
        )
    }

    @Test("A Nitro badge reads the same before the directory answers and after; only the film arrives")
    func nitroBeforeAndAfter() throws {
        let tier = try gold()
        let before = content(tenure: tier, since: try date())
        let after = content(badge: directoryEntry(), tenure: tier, since: try date())

        #expect(before.title == "Nitro Gold")
        #expect(before.title == after.title)
        #expect(before.line == "Subscriber since 3/2/26")
        #expect(before.line == after.line)
        #expect(before.titleSize == after.titleSize)
        #expect(before.still == after.still)
        #expect(before.graphicHeight == after.graphicHeight)
        #expect(before.film == nil)
        #expect(after.film == film)
    }

    @Test("Its still is the tier's own edge-to-edge drawing, not the directory's")
    func nitroStill() throws {
        let tier = try gold()
        #expect(content(badge: directoryEntry(), tenure: tier).still == tier.artworkURL)
    }

    @Test("Less motion takes the film away and leaves the rest")
    func reducedMotion() throws {
        let tier = try gold()
        let still = content(badge: directoryEntry(), tenure: tier, reducesMotion: true)
        #expect(still.film == nil)
        #expect(still.still == tier.artworkURL)
        #expect(still.title == "Nitro Gold")
    }

    @Test("A date the directory hasn't given is left unsaid")
    func noDate() throws {
        #expect(content(tenure: try gold()).line == nil)
    }

    @Test("The plain `premium` badge names no tier, and its directory entry still reads as Nitro")
    func untieredNitro() {
        let entry = directoryEntry()
        let card = content(badge: entry, tenure: nil)
        #expect(card.title == "Nitro Gold")
        #expect(card.still == directoryStill)
        #expect(card.film == film)
        #expect(card.graphicHeight == BadgeCardContent.nitroHeight)
    }

    @Test("A levelled badge keeps its eyebrow and its size")
    func levelled() {
        let entry = CatalogBadge(
            badgeID: BadgeKind.streaming.rawValue, name: "Streaming", isOwned: true, currentTierKey: "breakout",
            tiers: [BadgeTier(key: "breakout", name: "Breakout", complexIconURL: directoryStill)],
            infoLabel: "23 hours streamed to others"
        )
        let card = content(badge: entry)
        #expect(card.eyebrow == "Streaming")
        #expect(card.title == "Breakout")
        #expect(card.line == "23 hours streamed to others")
        #expect(card.still == directoryStill)
        #expect(card.film == nil)
        #expect(card.graphicHeight == BadgeCardContent.levelledHeight)
    }

    @Test("A badge nobody has described draws the profile's own words and icon")
    func plain() {
        let icon = URL(string: "https://cdn.discordapp.com/badge-icons/x.png")
        let card = content(label: "HypeSquad Brilliance", iconURL: icon)
        #expect(card.title == "HypeSquad Brilliance")
        #expect(card.line == nil)
        #expect(card.still == icon)
        #expect(card.graphicHeight == BadgeCardContent.plainHeight)
    }

    /// A popover takes its size from its first layout, so a slot that grew when
    /// its picture landed left the picture squeezed into the old height: 28 points
    /// across, on Alex's image 49.
    @Test("The picture's slot is its full height before anything has landed")
    func slotIsFixed() throws {
        let tier = try gold()
        let card = BadgeCard(tenure: tier, premiumSince: try date(), label: "Nitro", iconURL: nil)
        let host = NSHostingView(rootView: card.environment(AppModel()))
        let height = host.fittingSize.height
        // The drawing and the card's padding alone, before a word of text.
        #expect(height > BadgeCardContent.nitroHeight + 2 * Spacing.group)
    }

    @Test("The film's drawing comes out the height of the still's")
    func filmMatchesStill() {
        // Discord's moving Gold: 142 of its 200 rows are drawing.
        let drawn = BadgeGraphic.filmScale * 142 / 200
        #expect(abs(drawn - 1) < 0.01)
    }
}
