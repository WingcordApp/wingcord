import AppKit
import CoreGraphics
import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// The buttons an app attaches to a message.
@MainActor
@Suite("Message components")
struct ComponentLayoutTests {

    private func button(
        _ label: String,
        url: String? = nil,
        disabled: Bool = false
    ) -> MessageComponent {
        MessageComponent(
            id: label,
            label: label,
            kind: url.map { MessageComponent.Kind.link($0) } ?? .action,
            style: url == nil ? .primary : .link,
            isDisabled: disabled
        )
    }

    private func rows(_ actionRows: [ActionRow], width: CGFloat = 400) -> [ComponentSlot] {
        let items: [TimelineItem] = [.message(TimelineMessage(
            message: Message(
                id: MessageID(rawValue: 1),
                channelID: ChannelID(rawValue: 1),
                authorID: UserID(rawValue: 1),
                content: "See below",
                payload: MessagePayload(components: actionRows)
            ),
            flags: [.head, .tail]
        ))]
        let engine = TimelineLayoutEngine(presentationRevision: 1)
        var cache: [TimelineLayoutEngine.CacheKey: MessageRow] = [:]
        let laid = engine.layout(
            TimelineLayoutEngine.Input(
                items: items,
                width: width,
                style: MessageTextStyle.current(),
                mentions: MentionContext(),
                channelName: "general",
                authors: [:],
                calendar: .current,
                settings: .comfortable
            ),
            cache: &cache
        )
        guard case .message(let row) = laid[0].kind else { return [] }
        return row.components
    }

    @Test("Only a link button is live")
    func onlyLinksAreLive() {
        let slots = rows([ActionRow(components: [
            button("View release", url: "https://example.test/r"),
            button("Refresh"),
            button("Gone", url: "https://example.test/g", disabled: true),
        ])])
        #expect(slots.count == 3)
        #expect(slots[0].isEnabled)
        #expect(slots[0].url == "https://example.test/r")
        // Needs an interaction round trip this client does not make.
        #expect(!slots[1].isEnabled)
        #expect(slots[1].url == nil)
        // Disabled by the app itself, URL or not.
        #expect(!slots[2].isEnabled)
        #expect(slots[2].url == nil)
    }

    @Test("Buttons on one action row share a line")
    func oneRowIsOneLine() {
        let slots = rows([ActionRow(components: [button("A"), button("B"), button("C")])])
        #expect(Set(slots.map(\.rect.minY)).count == 1)
    }

    @Test("Two action rows stack")
    func rowsStack() {
        let slots = rows([
            ActionRow(components: [button("A")]),
            ActionRow(components: [button("B")]),
        ])
        #expect(slots.count == 2)
        #expect(slots[1].rect.minY > slots[0].rect.minY)
    }

    /// A row of buttons wider than the column wraps instead of running off the
    /// trailing edge — an app can attach five, and the transcript has no
    /// horizontal scroll to escape into.
    @Test("A row wider than the column wraps")
    func wideRowWraps() {
        let labels = (0..<5).map { button("A fairly long button label \($0)") }
        let slots = rows([ActionRow(components: labels)], width: 400)
        #expect(Set(slots.map(\.rect.minY)).count > 1)
        for slot in slots {
            #expect(slot.rect.maxX <= 400)
        }
    }

    /// A select menu is drawn as its own placeholder and is never live: picking
    /// from one is an interaction round trip this client does not make.
    @Test("A menu draws its placeholder and cannot be used")
    func menuIsDrawnAndInert() {
        let slots = rows([ActionRow(components: [
            MessageComponent(
                id: "pick", label: "Choose a role", kind: .menu, isDisabled: true
            ),
        ])])
        #expect(slots.count == 1)
        #expect(slots[0].isMenu)
        #expect(!slots[0].isEnabled)
        #expect(slots[0].label == "Choose a role")
    }
}
