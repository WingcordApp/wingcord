import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// The Rich Presence builder's model (DESIGN-NOTES §11): one card on at a
/// time, in place of the detected game, on the account's activity sharing.
///
/// **Serialized, and every test restores the cards it found** — they live in
/// `AppSettings`, which the whole run shares.
@Suite("Rich Presence builder", .serialized)
@MainActor
struct RichPresenceBuilderTests {

    private func clean(_ body: (AppModel, AppSettings) throws -> Void) async rethrows {
        try await withAppSettings(\.customPresences, \.activeCustomPresenceID, \.sharesGameActivity) { settings in
            settings.activeCustomPresenceID = nil
            settings.customPresences = []
            settings.sharesGameActivity = true
            try body(AppModel(), settings)
        }
    }

    private func named(_ name: String, in model: AppModel) -> CustomPresence.ID {
        let id = model.addCustomPresence()
        var presence = model.customPresences.first { $0.id == id }!
        presence.name = name
        model.updateCustomPresence(presence)
        return id
    }

    private let game = DetectedGame(
        id: ApplicationID(rawValue: 5), name: "Celeste", startedAt: .now,
        isLauncher: false, isTranslated: false, processIdentifier: 1
    )

    @Test("A card that is on replaces the detected game")
    func replacesGame() async {
        await clean { model, _ in
            model.detectedGame = game
            #expect(model.publishedActivities.map(\.name) == ["Celeste"])
            let id = named("Hollow Knight", in: model)
            #expect(model.publishedActivities.map(\.name) == ["Celeste"], "a card that is off changes nothing")
            model.setCustomPresenceOn(id)
            #expect(model.publishedActivities.map(\.name) == ["Hollow Knight"])
            model.setCustomPresenceOn(nil)
            #expect(model.publishedActivities.map(\.name) == ["Celeste"])
        }
    }

    @Test("One card is on at a time, and Show Custom RPC brings the last one back")
    func oneAtATime() async {
        await clean { model, _ in
            let first = named("One", in: model)
            let second = named("Two", in: model)
            model.setCustomPresenceOn(first)
            model.setCustomPresenceOn(second)
            #expect(model.publishedActivities.map(\.name) == ["Two"])
            model.toggleShowsCustomPresence()
            #expect(!model.showsCustomPresence)
            model.toggleShowsCustomPresence()
            #expect(model.activeCustomPresence?.id == second)
        }
    }

    @Test("A card that breaks a rule, or no activity sharing, sends nothing")
    func nothingSent() async {
        await clean { model, settings in
            let id = named("Fine", in: model)
            model.setCustomPresenceOn(id)
            var presence = model.activeCustomPresence!
            presence.detailsLink = "not a link"
            model.updateCustomPresence(presence)
            #expect(model.publishedActivities.isEmpty)
            presence.detailsLink = ""
            model.updateCustomPresence(presence)
            #expect(model.publishedActivities.count == 1)
            settings.sharesGameActivity = false
            #expect(model.publishedActivities.isEmpty)
        }
    }

    @Test("Removing the card that is on turns it off")
    func removeActive() async {
        await clean { model, _ in
            let id = named("Gone", in: model)
            model.setCustomPresenceOn(id)
            model.removeCustomPresence(id)
            #expect(model.activeCustomPresence == nil)
            #expect(model.customPresences.isEmpty)
        }
    }
}
