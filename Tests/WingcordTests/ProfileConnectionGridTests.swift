import AppKit
import SwiftUI
import Testing
import WingcordCore
@testable import Wingcord

/// A profile's connections: even one-line tiles, and a tile grown into a card
/// with everything it knows. Drawn with `WINGCORD_RENDER_DIR` set.
@MainActor
@Suite("Profile connection grid")
struct ProfileConnectionGridTests {

    private let connections = [
        ConnectedAccount(id: "1", service: "playstation", name: "mikecasey_the_great_gamer", isVerified: true),
        ConnectedAccount(
            id: "2", service: "tiktok", name: "mik3casey_official", isVerified: true,
            metadata: ["follower_count": "32", "following_count": "191", "likes_count": "5"]
        ),
        ConnectedAccount(id: "3", service: "twitch", name: "mikecaseylive", isVerified: true),
        ConnectedAccount(id: "4", service: "youtube", name: "Mike", isVerified: true),
    ]

    @Test("Every tile is one line tall, whatever the account published")
    func evenTiles() throws {
        let grid = ProfileConnectionGrid(connections: connections)
            .environment(\.colorScheme, .dark)
        let result = try SurfaceRender.render(grid, named: "connections-at-rest", width: 420)
        // Two rows of 52-point tiles, a gap, and the renderer's margin.
        #expect(abs(result.size.height - (52 * 2 + Spacing.base + 24)) < 1)
    }

    @Test("A grown tile carries the counts and the two actions")
    func grownCard() throws {
        let card = ProfileConnectionCard(connection: connections[1], isExpanded: true, setExpanded: { _ in })
            .frame(width: 200)
            .padding(.bottom, 170)
            .environment(\.colorScheme, .dark)
        let result = try SurfaceRender.render(card, named: "connections-grown", width: 240)
        #expect(result.ink > 0.05)
    }
}
