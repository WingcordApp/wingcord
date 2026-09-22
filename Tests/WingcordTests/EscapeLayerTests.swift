import Foundation
import Testing
@testable import Wingcord
import WingcordCore

/// Which floating layer owns Escape.
///
/// **The bug this pins is silent and looks like nothing happening.** SwiftUI
/// settles a contested `.cancelAction` by view hierarchy rather than by what is
/// drawn on top, so a layer that forgets to give the shortcut up sends Escape to
/// whatever is *underneath* the thing the reader is looking at — the profile
/// closed while its own badge page stayed open over an empty window. Every
/// caller spelling out its own exclusions is how a layer added later gets left
/// out of four predicates at once, so the order lives in one place and this
/// asserts it.
@MainActor
@Suite("Escape layers")
struct EscapeLayerTests {

    private func model() -> AppModel {
        let model = AppModel()
        model.profileRequest = ProfileRequest(userID: UserID(rawValue: 7), anchor: .zero)
        return model
    }

    @Test("Nothing open, nothing covered")
    func nothingOpen() {
        let model = AppModel()
        #expect(model.escapeLayer == nil)
        // **Not covered, and this is the distinction that matters**: a layer
        // that is not open is also not the top one, and answering "covered"
        // would take the shortcut from a control that is about to want it.
        #expect(!model.isCovered(.profile))
        #expect(!model.isCovered(.tenureBadge))
    }

    @Test("A profile alone owns it")
    func profileAlone() {
        let model = model()
        #expect(model.escapeLayer == .profile)
        #expect(!model.isCovered(.profile))
    }

    @Test("A tenure page opened from that profile takes it")
    func tenurePageWins() throws {
        let model = model()
        let tier = try #require(PremiumTenure.named("premium_tenure_3_month_v2"))
        model.tenureBadgeRequest = TenureBadgeRequest(tenure: tier, premiumSince: nil)
        #expect(model.escapeLayer == .tenureBadge)
        #expect(model.isCovered(.profile))
        #expect(!model.isCovered(.tenureBadge))
    }

    @Test("And a game profile under it does not")
    func orderIsTopDown() throws {
        let model = model()
        model.gameProfileRequest = GameProfileRequest(gameID: ApplicationID(rawValue: 1))
        #expect(model.escapeLayer == .gameProfile)
        #expect(model.isCovered(.profile))

        let tier = try #require(PremiumTenure.named("premium_tenure_72_month_v2"))
        model.tenureBadgeRequest = TenureBadgeRequest(tenure: tier, premiumSince: nil)
        #expect(model.escapeLayer == .tenureBadge)
        #expect(model.isCovered(.gameProfile))
        #expect(model.isCovered(.profile))
    }

    @Test("The quick switcher covers everything, because a key raised it")
    func quickSwitcherCoversAll() throws {
        let model = model()
        let tier = try #require(PremiumTenure.named("premium_tenure_3_month_v2"))
        model.tenureBadgeRequest = TenureBadgeRequest(tenure: tier, premiumSince: nil)
        model.gameProfileRequest = GameProfileRequest(gameID: ApplicationID(rawValue: 1))
        model.toggleQuickSwitch()

        #expect(model.escapeLayer == .quickSwitcher)
        #expect(model.isCovered(.profile))
        #expect(model.isCovered(.gameProfile))
        #expect(model.isCovered(.tenureBadge))
    }

    // MARK: What the drawn canvases read

    @Test("An empty window is not covered")
    func anEmptyWindowIsNotCovered() {
        // The transcript hovers, plays avatars and raises its action bar
        // whenever this is false, which is nearly always — so the cheap answer
        // has to be the common one.
        #expect(!AppModel().isWindowCovered)
    }

    @Test("Every floating layer covers the canvases underneath it")
    func everyLayerCovers() throws {
        // **The defect this pins was visible and looked like a rendering
        // fault.** A tracking area is not occlusion-tested, so the transcript
        // went on lighting rows under an open profile and its hover action bar
        // stuck out from behind the card. One list of layers answers it for all
        // of them — a second list is how the next one added gets left out.
        let profile = AppModel()
        profile.profileRequest = ProfileRequest(userID: UserID(rawValue: 7), anchor: .zero)
        #expect(profile.isWindowCovered)

        let game = AppModel()
        game.gameProfileRequest = GameProfileRequest(gameID: ApplicationID(rawValue: 1))
        #expect(game.isWindowCovered)

        let tenure = AppModel()
        tenure.tenureBadgeRequest = TenureBadgeRequest(
            tenure: try #require(PremiumTenure.named("premium_tenure_3_month_v2")),
            premiumSince: nil
        )
        #expect(tenure.isWindowCovered)

        let switcher = AppModel()
        switcher.toggleQuickSwitch()
        #expect(switcher.isWindowCovered)
    }

    @Test("A page opened from the DM column, with no profile behind it")
    func tenureWithoutAProfile() throws {
        let model = AppModel()
        let tier = try #require(PremiumTenure.named("premium_tenure_12_month_v2"))
        model.tenureBadgeRequest = TenureBadgeRequest(tenure: tier, premiumSince: nil)
        // The badge row also lives in the direct-message column, which is not a
        // presentation at all — so the page can be the only layer open.
        #expect(model.escapeLayer == .tenureBadge)
        #expect(!model.isCovered(.tenureBadge))
    }
}
