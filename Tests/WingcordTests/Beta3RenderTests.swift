import Foundation
import SwiftUI
import Testing
import WingcordCore
@testable import Wingcord

/// Beta 3's new surfaces, drawn offscreen (`WINGCORD_RENDER_DIR` writes the
/// pictures): a bot's form on the form card with every kind of field, and the
/// composer's bars (docs/BETA3.md §2.3, §2.4).
@MainActor
@Suite("Beta 3 surfaces, drawn offscreen", .serialized)
struct Beta3RenderTests {

    private func formModel() -> AppModel {
        let model = AppModel()
        let areas = ["Messages", "Voice", "Video", "Screen Share", "Notifications", "Profiles",
                     "Servers & Channels", "Appearance", "Settings", "Speed & Freezes", "Crash",
                     "Signing In", "Something Else"]
        let modal = InteractionModal(
            id: "1",
            customID: "publish",
            title: "Publish this report",
            channelID: ChannelID(rawValue: 2),
            applicationID: ApplicationID(rawValue: 3),
            applicationName: "Wingcord",
            fields: [
                .label(text: "Title", description: "The post's name and the issue's title.", field: .textInput(
                    InteractionModal.TextInput(
                        customID: "title", label: nil, isParagraph: false,
                        value: "Some servers open empty", placeholder: nil,
                        isRequired: true, minLength: nil, maxLength: 100
                    )
                )),
                .label(text: "What happened", description: "As it will read in public.", field: .textInput(
                    InteractionModal.TextInput(
                        customID: "what", label: nil, isParagraph: true,
                        value: "The channel list is empty in a server with rules.", placeholder: nil,
                        isRequired: true, minLength: nil, maxLength: 4000
                    )
                )),
                .label(text: "Area", description: "Labels the issue on GitHub.", field: .select(SelectMenu(
                    customID: "area",
                    placeholder: "Choose an area",
                    options: areas.map { SelectMenu.Option(label: $0, value: $0) },
                    minValues: 1,
                    maxValues: 1
                ))),
                .label(text: "Who saw it", description: nil, field: .entitySelect(.init(
                    kind: .user, customID: "who", placeholder: "Choose people",
                    minValues: 0, maxValues: 3, isRequired: false
                ))),
                .label(text: "Screenshots", description: nil, field: .fileUpload(.init(
                    customID: "shots", minValues: 0, maxValues: 3, isRequired: false
                ))),
            ]
        )
        var answers = modal.initialAnswers
        answers["area"] = .values(["Servers & Channels"])
        model.interactionModal = InteractionModalState(modal: modal, answers: answers)
        return model
    }

    @Test("A bot's form fits its card, and its dropdown is closed")
    func formFitsItsCard() throws {
        let model = formModel()
        let result = try SurfaceRender.render(
            InteractionFormSheet().environment(model),
            named: "beta3-form",
            width: 480
        )
        #expect(result.ink > 0.05)
        // Fourteen areas laid open made it taller than a screen; closed, the
        // whole form is well under one.
        #expect(result.size.height < 900)
    }

    @Test("The composer's bars draw their sentence and button")
    func composerBars() throws {
        let bars: [(String, ComposerBlock)] = [
            ("beta3-bar-complete", .completeSteps),
            ("beta3-bar-review", .applicationAwaitingReview),
            ("beta3-bar-wait", .memberAge(until: .now.addingTimeInterval(299))),
        ]
        for (name, block) in bars {
            let result = try SurfaceRender.render(ComposerBlockBar(block: block) { _ in }, named: name, width: 720)
            #expect(result.ink > 0.02, "\(name)")
        }
    }
}
