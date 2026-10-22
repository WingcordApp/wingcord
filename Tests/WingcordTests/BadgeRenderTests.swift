import AppKit
import SwiftUI
import Testing
import WingcordCore
@testable import Wingcord

/// Phase 8's badge surfaces over the demo's directory, drawn offscreen — PNGs
/// with `WINGCORD_RENDER_DIR` set. Glass does not composite here.
@MainActor
@Suite("Badge renders")
struct BadgeRenderTests {

    private func model() -> AppModel {
        let model = AppModel()
        DemoFixtures.populate(model)
        return model
    }

    @Test("A levelled badge's card, and a plain one's")
    func cards() throws {
        let model = self.model()
        let me = try #require(model.currentUserID)
        let catalog = try #require(model.badgeCatalogs[me])
        let streaming = try #require(catalog.first { $0.badgeID == BadgeKind.streaming.rawValue })
        let size = try render(BadgeCard(badge: streaming, label: "Streaming", iconURL: nil).environment(model), named: "badge-card-levelled")
        #expect(size.height > 150)
        let plain = try render(BadgeCard(badge: nil, label: "HypeSquad Brilliance", iconURL: nil).environment(model), named: "badge-card-plain")
        #expect(plain.height > 30)
    }

    @Test("The directory, opened on Game Time")
    func directory() throws {
        let model = self.model()
        let me = try #require(model.currentUserID)
        let size = try render(
            BadgeDirectory(userID: me, initialBadgeID: BadgeKind.gameTime.rawValue, customize: {}).environment(model),
            named: "badge-directory"
        )
        #expect(size.width >= 700)
    }

    @Test("Customize your badges")
    func customizer() throws {
        let model = self.model()
        let me = try #require(model.currentUserID)
        let size = try render(BadgeCustomizer(userID: me, viewBadges: {}).environment(model), named: "badge-customizer")
        #expect(size.width >= 400)
    }

    private func render(_ view: some View, named name: String) throws -> CGSize {
        let host = NSHostingView(rootView: view.padding(12).background(Color(white: 0.11)))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        guard let directory = ProcessInfo.processInfo.environment["WINGCORD_RENDER_DIR"],
              let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)
        else { return host.bounds.size }
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        return host.bounds.size
    }
}
