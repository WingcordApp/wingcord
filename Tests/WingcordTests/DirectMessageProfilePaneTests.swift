import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Wingcord
@testable import WingcordCore

/// The profile column beside a direct message, for somebody wearing a frame.
///
/// **Neither half can be seen in a test of its own piece.** The hold is a flag
/// the projection derives from two tables, so it is asserted through
/// `profilePresentation(for:)`, which the container actually calls; the
/// column's width is padding a modifier adds around the box, so it is asserted
/// by laying the real pane out.
///
/// **Serialized**, because one case moves a preference on the shared
/// `AppSettings` and the projection reads it back.
@MainActor
@Suite("DM profile column", .serialized)
struct DirectMessageProfilePaneTests {

    private let them = UserID(rawValue: 2)
    private let sku = "1515124557290410204"

    /// Dark Roses (Blue), as `GET /collectibles-products/{sku}` sends it.
    private var darkRoses: ProfileFrame {
        ProfileFrame(
            skuID: sku,
            label: "Blue roses…",
            innerWidth: 1200,
            overflowTop: 211,
            overflowBottom: 186,
            overflowHorizontal: 56,
            layers: [
                ProfileFrame.Layer(
                    id: "top",
                    url: URL(string: "https://example.invalid/top")!,
                    anchor: .top,
                    order: .front
                ),
            ]
        )
    }

    /// Somebody whose profile names the frame — the shape the profile route
    /// leaves on the store before the collectible has answered.
    private func model() -> AppModel {
        let model = AppModel()
        model.users[them] = User(
            id: them,
            username: "someone",
            decoration: UserDecoration(profileFrameSKU: sku)
        )
        return model
    }

    private func profile(in model: AppModel) -> ProfilePresentation? {
        model.profilePresentation(for: ProfileRequest(
            userID: them,
            guildID: nil,
            anchor: .zero,
            depth: .full
        ))
    }

    /// The width the pane asks for, laid out as the workspace lays it out.
    private func columnWidth(for profile: ProfilePresentation?, in model: AppModel) -> CGFloat {
        let pane = DirectMessageProfilePane(profile: profile, openFullProfile: { _ in })
            .environment(model)
        return NSHostingView(rootView: pane).fittingSize.width
    }

    // MARK: The hold

    @Test("A frame the profile names holds the column until it has resolved")
    func holdsForTheFrame() {
        let model = model()
        model.collectiblesLoading = [sku]
        let waiting = profile(in: model)
        #expect(waiting?.isFrameLoading == true)
        #expect(waiting?.frame == nil)

        model.collectiblesLoading = []
        model.profileFrames[sku] = darkRoses
        let resolved = profile(in: model)
        #expect(resolved?.isFrameLoading == false)
        #expect(resolved?.frame == darkRoses)
    }

    /// **Not in flight is not held**, whether the frame's fetch failed or was
    /// never started: `loadCollectible` empties the set on every way out, so a
    /// frame that never resolves costs the frame and never the card.
    @Test("A frame that is not being fetched holds nothing")
    func releasesWithoutAFrame() {
        let model = model()
        #expect(profile(in: model)?.isFrameLoading == false)
    }

    @Test("A reader who switched frames off is never held for one")
    func suppressedFrameHoldsNothing() async {
        await withAppSettings(\.suppressedCosmetics) { settings in
            settings.suppressedCosmetics = .profileFrames

            let model = model()
            model.collectiblesLoading = [sku]
            #expect(profile(in: model)?.isFrameLoading == false)
        }
    }

    // MARK: The column

    /// **The box keeps its width and the column grows by the sides** —
    /// measured on Discord's own stylesheets in Chrome, where a frame took the
    /// column from 320 to 348.4 and left the card at 304. Dark Roses on this
    /// column's 288-point card overhangs 13 points a side.
    @Test("A frame widens the column by its two side overhangs")
    func frameWidensTheColumn() {
        let model = model()
        model.profileFrames[sku] = darkRoses
        let framed = profile(in: model)
        let overhang = darkRoses.overhang(cardWidth: Proportions.profileColumnIdeal)
        #expect(overhang.leading == 13)

        let bare = Proportions.profileColumnIdeal + Spacing.base * 2
        #expect(columnWidth(for: framed, in: model) == bare + overhang.leading * 2)
    }

    @Test("A column held for its frame keeps the width it had")
    func heldColumnKeepsItsWidth() {
        let model = model()
        model.collectiblesLoading = [sku]
        let bare = Proportions.profileColumnIdeal + Spacing.base * 2
        #expect(columnWidth(for: profile(in: model), in: model) == bare)
    }
}
