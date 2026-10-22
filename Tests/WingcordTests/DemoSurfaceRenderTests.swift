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

    /// Lays the view out on the app's dark ground and, when asked, writes it
    /// out at 2×.
    private func render(_ view: some View, named name: String, width: CGFloat? = nil) throws -> CGSize {
        let host = NSHostingView(rootView: view.frame(width: width).padding(12).background(Color(white: 0.11)))
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
