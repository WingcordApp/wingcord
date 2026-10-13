import AppKit
import SwiftUI
import Testing
import WingcordCore
@testable import Wingcord

/// The Rich Presence builder's card keeps to the profile's column: hosted at
/// a column's width, it reports that width and a card's height, whatever it
/// holds.
@MainActor
struct EditablePresenceCardTests {
    private static let column: CGFloat = 420

    private func fitting(_ presence: CustomPresence, isOn: Bool = false) -> CGSize {
        let card = EditablePresenceCard(
            presence: presence, isOn: isOn, ground: ProfileGround(themeColorValues: []),
            update: { _ in }, turnOn: { _ in }, remove: {}
        )
        .frame(width: Self.column)
        .environment(AppModel())
        return NSHostingView(rootView: card).fittingSize
    }

    @Test("An empty card is a card's height and the column's width")
    func empty() {
        let size = fitting(CustomPresence())
        #expect(size.width == Self.column)
        #expect(size.height > CurrentActivityCard.artworkSide)
        #expect(size.height < 400)
    }

    /// Every line full, every problem said: still the column's width.
    @Test("A full card with its problems said stays in the column")
    func full() {
        var presence = CustomPresence()
        presence.name = String(repeating: "Hollow Knight ", count: 12)
        presence.details = String(repeating: "Greenpath ", count: 20)
        presence.detailsLink = "not a link"
        presence.kind = .streaming
        presence.streamLink = "https://example.com"
        presence.timer = .custom(start: .now, end: .now.addingTimeInterval(3_600))
        presence.buttons[0].label = String(repeating: "b", count: 40)
        let size = fitting(presence, isOn: true)
        #expect(size.width == Self.column)
        #expect(size.height > fitting(CustomPresence()).height)
    }
}
