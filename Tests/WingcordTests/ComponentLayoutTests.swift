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
            kind: url.map { MessageComponent.Kind.link($0) } ?? .action(customID: label),
            style: url == nil ? .primary : .link,
            isDisabled: disabled
        )
    }

    private func rows(_ actionRows: [ActionRow], width: CGFloat = 400) -> [ComponentSlot] {
        laidOut(
            Message(
                id: MessageID(rawValue: 1),
                channelID: ChannelID(rawValue: 1),
                authorID: UserID(rawValue: 1),
                content: "See below",
                payload: MessagePayload(components: actionRows)
            ),
            width: width
        )?.components ?? []
    }

    /// The whole laid-out row, for the parts of it that are not components.
    private func laidOut(_ message: Message, width: CGFloat = 400) -> MessageRow? {
        let items: [TimelineItem] = [.message(TimelineMessage(
            message: message,
            flags: [.head, .tail]
        ))]
        let engine = TimelineLayoutEngine(presentationRevision: 1)
        var cache: [MessageID: TimelineLayoutEngine.CacheEntry] = [:]
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
        guard case .message(let row) = laid[0].kind else { return nil }
        return row
    }

    /// **A link and an action are both live, and never the same one.** A slot
    /// carries a `url` or a `customID`, and the painter's dimming now means
    /// "this genuinely cannot be pressed" rather than "this client does not
    /// make interactions".
    @Test("A link opens, an action posts, and a disabled control does neither")
    func linksOpenAndActionsPost() {
        let slots = rows([ActionRow(components: [
            button("View release", url: "https://example.test/r"),
            button("Refresh"),
            button("Gone", url: "https://example.test/g", disabled: true),
            button("Off", disabled: true),
        ])])
        #expect(slots.count == 4)

        #expect(slots[0].isEnabled)
        #expect(slots[0].url == "https://example.test/r")
        #expect(slots[0].customID == nil)

        #expect(slots[1].isEnabled)
        #expect(slots[1].url == nil)
        #expect(slots[1].customID == "Refresh")

        // Disabled by the app itself, URL or not.
        #expect(!slots[2].isEnabled)
        #expect(slots[2].url == nil)
        #expect(slots[2].customID == nil)

        // …and the same for an action button the app switched off — the pager's
        // Prev on page one.
        #expect(!slots[3].isEnabled)
        #expect(slots[3].customID == nil)
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

// MARK: - The ephemeral note

/// "Only you can see this", under a message nobody else received.
///
/// An ephemeral message is delivered over the socket to the one session that
/// caused it and exists nowhere else — not in history, gone on reload. The note
/// is how the reader learns that, and it is the difference between a reply that
/// vanished and a reply that was never anybody else's.
@Suite("Ephemeral messages")
struct EphemeralNoteTests {

    private func row(flags: MessageFlags, reactions: [Reaction] = []) -> TimelineRow? {
        let items: [TimelineItem] = [.message(TimelineMessage(
            message: Message(
                id: MessageID(rawValue: 1),
                channelID: ChannelID(rawValue: 1),
                authorID: UserID(rawValue: 1),
                content: "Outlook not so good",
                flags: flags,
                payload: reactions.isEmpty ? nil : MessagePayload(reactions: reactions)
            ),
            flags: [.head, .tail]
        ))]
        let engine = TimelineLayoutEngine(presentationRevision: 1)
        var cache: [MessageID: TimelineLayoutEngine.CacheEntry] = [:]
        let laid = engine.layout(
            TimelineLayoutEngine.Input(
                items: items,
                width: 400,
                style: MessageTextStyle.current(),
                mentions: MentionContext(),
                channelName: "general",
                authors: [:],
                calendar: .current,
                settings: .comfortable
            ),
            cache: &cache
        )
        guard case .message = laid[0].kind else { return nil }
        return laid[0]
    }

    /// The message half of a laid row.
    private func message(_ row: TimelineRow?) -> MessageRow? {
        guard case .message(let message) = row?.kind else { return nil }
        return message
    }

    @Test("The note appears only on an ephemeral message")
    func onlyWhenEphemeral() throws {
        #expect(message(row(flags: []))?.ephemeralNote == nil)
        let note = try #require(message(row(flags: [.ephemeral]))?.ephemeralNote)
        #expect(note.text == TimelineLayoutEngine.ephemeralNoteText)
        #expect(note.rect.width > 0)
    }

    /// **Only the control takes a click.** A target spanning the whole line
    /// would throw the message away on a click meant for nothing at all — and
    /// there is no undo, because the message exists nowhere else.
    @Test("Only the Dismiss run is a target, not the note beside it")
    func onlyTheControlIsATarget() throws {
        let note = try #require(message(row(flags: [.ephemeral]))?.ephemeralNote)
        #expect(note.dismissText == TimelineLayoutEngine.ephemeralDismissText)
        #expect(note.dismissRect.width > 0)

        // Inside the line…
        #expect(note.rect.contains(note.dismissRect))
        // …and clear of the note's own words, with the separator between them.
        let noteEnd = note.rect.minX + TimelineMetrics.ephemeralNoteGlyphRoom
            + TimelineLayoutEngine.measure(note.text, font: MessageTextStyle.current().metadataFont)
        #expect(note.dismissRect.minX > noteEnd)
        // The line ends where the control does: nothing follows it.
        #expect(abs(note.rect.maxX - note.dismissRect.maxX) < 0.5)
    }

    /// Under everything, which is where a note about the whole message belongs
    /// and where Discord's own sits.
    @Test("The note is laid out below the reactions")
    func sitsUnderEverything() throws {
        let reacted = try #require(
            message(
                row(
                    flags: [.ephemeral],
                    reactions: [Reaction(emoji: EmojiRef(name: "👍"), count: 1, isMine: false)]
                )
            )
        )
        let note = try #require(reacted.ephemeralNote)
        let chip = try #require(reacted.reactions.first)
        #expect(note.rect.minY >= chip.rect.maxY)
    }

    /// The row's height has to grow with it, or the note draws over whatever is
    /// beneath — a drawn canvas has no layout to catch that.
    @Test("The row is tall enough to hold it")
    func rowGrowsToFit() throws {
        let plain = try #require(row(flags: []))
        let ephemeral = try #require(row(flags: [.ephemeral]))
        let note = try #require(message(ephemeral)?.ephemeralNote)
        #expect(ephemeral.height > plain.height)
        #expect(ephemeral.height >= note.rect.maxY)
    }

    /// Spoken, not only drawn. Whether a message is private to the reader is the
    /// fact most easily missed in the quietest ink on the row, and the one that
    /// changes what somebody does next.
    @Test("VoiceOver is told")
    func isSpoken() throws {
        let ephemeral = try #require(message(row(flags: [.ephemeral])))
        #expect(ephemeral.accessibilityLabel.contains(TimelineLayoutEngine.ephemeralNoteText))
        #expect(try #require(message(row(flags: []))).accessibilityLabel
            .contains(TimelineLayoutEngine.ephemeralNoteText) == false)
    }
}
