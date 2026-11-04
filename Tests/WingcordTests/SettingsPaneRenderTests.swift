import AppKit
import SwiftUI
import Testing
import WingcordCore
@testable import WingcordNet
@testable import Wingcord

/// Every Settings pane, drawn over the demo's model (D10f, 4.7). With
/// `WINGCORD_RENDER_DIR` set each is written there as `settings-<pane>.png`;
/// without it they still lay out and draw, which is what catches a pane that
/// collapses or a switch that leaves it blank.
@MainActor
@Suite("Settings pane renders")
struct SettingsPaneRenderTests {

    private static let model: AppModel = {
        let model = AppModel()
        DemoFixtures.populate(model)
        return model
    }()

    @Test("Every pane lays out and draws", arguments: SettingsSection.allCases)
    func pane(_ section: SettingsSection) throws {
        let result = try SurfaceRender.render(
            SettingsPaneContent(section: section).environment(Self.model),
            named: "settings-\(section.rawValue)",
            width: 640
        )
        #expect(result.size.height > 120, "\(section) laid out \(result.size.height) pt tall")
        #expect(result.ink > 0.02, "\(section) drew \(result.ink) of its area")
    }
}

/// Server Settings' Boost Perks — the first pane the Settings pass reached
/// there (D10f): the progress bar's switch, and the two image wells, empty and
/// filled, at their own 16:9.
@MainActor
@Suite("Server Settings pane renders")
struct ServerSettingsPaneRenderTests {

    @Test("Boost Perks lays out with its wells empty and filled", arguments: [false, true])
    func boostPerks(filled: Bool) throws {
        let guildID = GuildID(rawValue: 1)
        let store = ServerSettingsStore(
            guildID: guildID,
            permissions: .administrator,
            channels: [],
            rest: DiscordREST(protocolClasses: [OfflineProtocol.self])
        )
        defer { store.cancelAll() }
        store.settings = .loaded(GuildSettings(
            id: guildID,
            name: "Sailors",
            bannerHash: filled ? "banner" : nil,
            splashHash: filled ? "splash" : nil,
            ownerID: UserID(rawValue: 9),
            isPremiumProgressBarEnabled: true,
            premiumTier: 2,
            premiumSubscriptionCount: 9
        ))
        let result = try SurfaceRender.render(
            BoostPerksPane(store: store, model: AppModel()),
            named: filled ? "server-boost-perks-filled" : "server-boost-perks-empty",
            width: 640
        )
        #expect(result.size.height > 300, "Boost Perks laid out \(result.size.height) pt tall")
        #expect(result.ink > 0.02)
    }
}
