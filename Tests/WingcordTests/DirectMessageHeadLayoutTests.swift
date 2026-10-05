import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Wingcord
@testable import WingcordCore

/// A conversation opens on Discord's heads (`aS`), not a channel's welcome: a
/// person's face and names, the servers in common and what can be done; a
/// group's sentence; Discord's own words in its system messages.
@MainActor
@Suite("Direct message heads")
struct DirectMessageHeadLayoutTests {

    private func head(_ head: ChannelHead, name: String = "Ana") -> ConversationStartSlot? {
        var cache: [MessageID: TimelineLayoutEngine.CacheEntry] = [:]
        let rows = TimelineLayoutEngine(presentationRevision: 1).layout(
            TimelineLayoutEngine.Input(
                items: [.conversationStart],
                width: 720,
                style: MessageTextStyle.current(),
                mentions: MentionContext(),
                channelName: name,
                head: head,
                authors: [:],
                calendar: .current,
                settings: PresentationRevision.shared.timeline
            ),
            cache: &cache
        )
        guard case .conversationStart(let slot)? = rows.first?.kind else { return nil }
        return slot
    }

    private func text(_ block: TimelineTextBlock?) -> String? { block.map { $0.text.attributed.string } }

    @Test("A person: their names, Discord's sentence, the request, servers in common, and the controls")
    func person() throws {
        let slot = try #require(head(.directMessage(DirectMessageHead(
            avatarURL: nil,
            monogram: "A",
            username: "ana_01",
            incomingRequestFrom: "Ana",
            mutualIcons: [.init(iconURL: nil, monogram: "W")],
            mutualCount: 2,
            actions: [.acceptRequest, .ignoreRequest, .block]
        ))))
        #expect(slot.isRound)
        #expect(text(slot.title) == "Ana")
        #expect(text(slot.subtitle) == "ana_01")
        #expect(text(slot.note) == "This is the beginning of your direct message history with Ana.\nAna sent you a friend request.")
        #expect(text(slot.mutuals?.label) == "2 Mutual Servers")
        #expect(slot.buttons.map { text($0.label) } == ["Accept Request", "Ignore Request", "Block"])
        #expect(slot.editButton == nil)
        #expect(slot.topic == nil)
    }

    @Test("Nobody in common reads Discord's line, and the line still opens the profile")
    func noMutuals() throws {
        let slot = try #require(head(.directMessage(DirectMessageHead(
            avatarURL: nil, monogram: "A", username: nil, incomingRequestFrom: nil,
            mutualIcons: [], mutualCount: 0, actions: [.addFriend, .block]
        ))))
        #expect(text(slot.mutuals?.label) == "No servers in common")
        let mutuals = try #require(slot.mutuals)
        #expect(slot.control(at: CGPoint(x: mutuals.rect.midX, y: mutuals.rect.midY))?.action == .mutualServers)
        // A sent request is drawn, and takes no click.
        let sent = try #require(head(.directMessage(DirectMessageHead(
            avatarURL: nil, monogram: "A", username: nil, incomingRequestFrom: nil,
            mutualIcons: [], mutualCount: 0, actions: [.friendRequestSent, .block]
        ))))
        let pending = try #require(sent.buttons.first)
        #expect(sent.control(at: CGPoint(x: pending.rect.midX, y: pending.rect.midY)) == nil)
    }

    @Test("A group, and Discord's own system messages")
    func groupAndSystem() throws {
        let group = try #require(head(.groupDirectMessage(iconURL: nil), name: "Raid night"))
        #expect(text(group.subtitle) == "Welcome to the beginning of the Raid night group.")
        #expect(group.isRound)
        let system = try #require(head(.systemDirectMessage(avatarURL: nil), name: "Discord"))
        #expect(text(system.subtitle) == "This is an official message from Team Discord. Please be advised that "
            + "Discord will never ask you for your password or account token.")
    }
}
