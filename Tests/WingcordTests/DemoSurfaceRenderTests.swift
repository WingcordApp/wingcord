import AppKit
import SwiftUI
import Testing
import WingcordCore
@testable import Wingcord

/// Phase 2's settings surfaces over the demo's own model, drawn offscreen —
/// with `WINGCORD_RENDER_DIR` set, each is written there as a PNG to look at;
/// without it they still lay out, which is what catches a pane that collapses.
/// Glass does not composite offscreen, so a control on it reads darker here
/// than on screen.
@MainActor
@Suite("Demo surface renders")
struct DemoSurfaceRenderTests {

    private func model() -> AppModel {
        let model = AppModel()
        DemoFixtures.populate(model)
        return model
    }

    @Test("Settings › Experiments, and Appearance with its saved themes")
    func panes() throws {
        let model = self.model()
        for (name, section) in [("pane-experiments", SettingsSection.experiments), ("pane-appearance", .appearance)] {
            let size = try render(SettingsPaneContent(section: section).environment(model), named: name, width: 640)
            #expect(size.height > 200, "\(name) laid out")
        }
    }

    @Test("The badge directory on the Server Booster: its own name, levels by milestone")
    func boosterBadge() throws {
        let model = self.model()
        let me = try #require(model.currentUserID)
        let size = try render(
            BadgeDirectory(userID: me, initialBadgeID: BadgeKind.guildBooster.rawValue) {}.environment(model),
            named: "badge-directory-booster"
        )
        #expect(size.height > 300)
    }

    @Test("Customize your badges: each tile one target, a hidden one struck through")
    func badgeCustomizer() throws {
        let model = self.model()
        let me = try #require(model.currentUserID)
        if var catalog = model.badgeCatalogs[me], let index = catalog.firstIndex(where: { $0.kind == .gameTime }) {
            catalog[index].isHidden = true
            model.badgeCatalogs[me] = catalog
        }
        let size = try render(BadgeCustomizer(userID: me) {}.environment(model), named: "badge-customizer")
        #expect(size.height > 200)
    }

    @Test("The colour picker: the rail's first notch and its thumb inside the rail's round end")
    func colourPicker() throws {
        // Red, so the thumb stands on the rail's leading end — where the
        // notch used to hang out of the capsule.
        let size = try render(PlayfulColourPicker(colour: .constant(0xFF0000)), named: "colour-picker")
        #expect(size.height > 150)
    }

    @Test("Game Servers: each card wears its game's box art and colour")
    func gameServers() throws {
        let model = self.model()
        let guildID = try #require(model.gameServers.first { !$0.value.isEmpty }?.key)
        model.selectedGuildID = guildID
        let presentation = try #require(model.gameServersPresentation)
        #expect(!presentation.games.isEmpty, "the servers' game resolved from its id")
        #expect(presentation.games.values.allSatisfy { $0.coverURL != nil })
        let size = try render(GameServersPane(presentation: presentation), named: "game-servers", width: 640)
        #expect(size.height > 300)
    }

    @Test("A profile card's status bubble: under the face's middle, beside its ring")
    func statusBubble() throws {
        let model = self.model()
        let me = model.currentUserID
        let request = try #require(
            model.users.keys.sorted { $0.rawValue < $1.rawValue }.lazy
                .filter { $0 != me }
                .map { ProfileRequest(userID: $0, showsMainProfile: true, anchor: .zero) }
                .first { model.profilePresentation(for: $0)?.customStatus?.isEmpty == false }
        )
        let profile = try #require(model.profilePresentation(for: request))
        let size = try render(
            MiniProfileCard(profile: profile, openFullProfile: { _ in }).environment(model),
            named: "profile-card-status"
        )
        #expect(size.height > 200)
    }

    @Test("Plumage, its Share beside Shuffle")
    func plumage() throws {
        let size = try render(PlumageCard().environment(model()), named: "plumage", width: 640)
        #expect(size.height > 200)
    }

    @Test("The share sheet, with the reader's blend in it")
    func shareSheet() throws {
        let model = self.model()
        let theme = SharedClientTheme(sharing: ThemeStore.shared.customSeed)
        let size = try render(ThemeShareSheet(theme: theme, dismiss: {}).environment(model), named: "theme-share-sheet")
        #expect(size.width >= 400)
    }

    @Test("Phase 3: Settings › Clips and Activity's game events over the demo's call")
    func clipsPanes() throws {
        let model = self.model()
        for (name, section) in [("pane-clips", SettingsSection.clips), ("pane-activity", .activity)] {
            let size = try render(SettingsPaneContent(section: section).environment(model), named: name, width: 640)
            #expect(size.height > 200, "\(name) laid out")
        }
    }

    @Test("Phase 3: the capture bar, and what it becomes while recording")
    func captureBar() throws {
        let controller = CaptureController()
        let bar = try render(CaptureBar(controller: controller), named: "capture-bar")
        #expect(bar.width > 400)
        let pill = try render(CaptureRecordingPill(controller: controller), named: "capture-pill")
        #expect(pill.width > 100)
    }

    private func render(_ view: some View, named name: String, width: CGFloat? = nil) throws -> CGSize {
        try SurfaceRender.render(view, named: name, width: width).size
    }
}
