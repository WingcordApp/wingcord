import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Wingcord
@testable import WingcordCore

/// AutoMod's messages and Discord's safety notices through the real layout:
/// AutoMod's own header over the member's message, the bar's buttons by what
/// the reader may do, and the safety card under a system message.
@MainActor
@Suite("AutoMod and safety cards")
struct AutoModLayoutTests {
    private let member = UserID(rawValue: 5)
    private let general = ChannelID(rawValue: 77)
    private let home = GuildID(rawValue: 1)

    private var mentions: MentionContext {
        var context = MentionContext()
        context.currentGuildID = home
        context.guildNames = [home: "Home"]
        context.channels = [general: LinkChannel(
            name: "general", guildID: home, kind: .text, canView: true, isPost: false, parentID: nil
        )]
        return context
    }

    private func autoModMessage(_ fields: [(String, String)], kind: String = "auto_moderation_message") -> Message {
        Message(
            id: MessageID(rawValue: 1 << 40),
            channelID: ChannelID(rawValue: 99),
            authorID: member,
            kind: .autoModerationAction,
            payload: MessagePayload(embeds: [Embed(
                kind: kind,
                description: "buy cheap gold now",
                fields: fields.map { Embed.Field(name: $0.0, value: $0.1, isInline: false) }
            )])
        )
    }

    private func row(_ message: Message, canManageMessages: Bool = false) -> MessageRow? {
        var cache: [MessageID: TimelineLayoutEngine.CacheEntry] = [:]
        var input = TimelineLayoutEngine.Input(
            items: [.message(TimelineMessage(message: message, flags: [.head, .tail]))],
            width: 720,
            style: MessageTextStyle.current(),
            mentions: mentions,
            channelName: "mod-log",
            authors: [member: TimelineLayoutEngine.AuthorInfo(
                name: "Spammer", colorValue: nil, avatarURL: nil, monogram: "S", decorationURL: nil, isBot: false
            )],
            calendar: .current,
            settings: PresentationRevision.shared.timeline
        )
        input.canManageMessages = canManageMessages
        let rows = TimelineLayoutEngine(presentationRevision: 1).layout(input, cache: &cache)
        return rows.lazy.compactMap { if case .message(let row) = $0.kind { row } else { nil } }.first
    }

    private func words(_ card: DrawnCard) -> [String] {
        card.parts.compactMap { if case .text(let block, _) = $0 { block.text.attributed.string } else { nil } }
    }

    private func actions(_ card: DrawnCard) -> [DrawnCardAction] {
        card.controls.map(\.action)
    }

    @Test("An alert: AutoMod's own header and sentence, the member inside the card, the matched words lit")
    func alert() throws {
        let laid = try #require(row(autoModMessage([
            ("decision_outcome", "blocked"), ("channel_id", "77"), ("rule_name", "No spam"),
            ("keyword", "gold"), ("keyword_matched_content", "gold"), ("flagged_message_id", "123"),
        ])))
        // None of the ordinary header: no face that would open the member from
        // AutoMod's picture.
        #expect(!laid.hasAuthorLine)
        #expect(laid.avatarRect == nil)
        let card = try #require(laid.card)
        #expect(card.parts.contains { if case .tag(.official, _) = $0 { true } else { false } })
        let text = words(card)
        #expect(text.contains("AutoMod"))
        let sentence = try #require(text.first { $0.hasPrefix("has blocked a message in ") })
        #expect(sentence.contains("general"))
        // One line: the chip brings no paragraph break with it.
        #expect(!sentence.contains("\n"))
        #expect(text.contains("Spammer"))
        #expect(text.contains("Keyword: gold"))
        #expect(text.contains("Rule: No spam"))
        let content = try #require(card.parts.lazy.compactMap { part -> TimelineTextBlock? in
            guard case .text(let block, _) = part, block.text.attributed.string == "buy cheap gold now" else { return nil }
            return block
        }.first)
        #expect(content.text.plates.map(\.range) == [NSRange(location: 10, length: 4)])
        // The face and the name open the member; the card opens the message.
        #expect(actions(card).filter { $0 == .person(member) }.count == 2)
        #expect(actions(card).contains(.openFlaggedMessage(MessageID(rawValue: 123), in: general)))
        #expect(actions(card).contains(.moderate(member)))
        #expect(actions(card).contains(.jumpToSurrounding(general)))
        #expect(!actions(card).contains(.deleteFlaggedMessage))
        #expect(laid.embeds.isEmpty)
    }

    @Test("Delete User's Message for a moderator, until somebody has done it")
    func deleteButton() throws {
        let fields = [("flagged_message_id", "123"), ("channel_id", "77")]
        let card = try #require(row(autoModMessage(fields), canManageMessages: true)?.card)
        #expect(actions(card).contains(.deleteFlaggedMessage))
        let done = #"{"actions":{"3":{"actor":"8","ts":"2026-10-05T10:00:00.000Z"}}}"#
        let handled = try #require(row(
            autoModMessage(fields + [("alert_actions_execution", done)]), canManageMessages: true
        )?.card)
        #expect(!actions(handled).contains(.deleteFlaggedMessage))
        #expect(handled.tips.map(\.action.kind) == [.deleteUserMessage])
    }

    @Test("A channel nobody here can name is Discord's bold unknown-channel")
    func unknownChannel() throws {
        let card = try #require(row(autoModMessage([("channel_id", "555")]))?.card)
        #expect(words(card).contains { $0.hasPrefix("has flagged a message in unknown-channel") })
        // And the card has nowhere to open.
        #expect(!actions(card).contains { if case .openFlaggedMessage = $0 { true } else { false } })
    }

    @Test("A notice: safety alert! for a raid; Discord's two buttons for a mention raid")
    func notices() throws {
        let raid = try #require(row(autoModMessage(
            [("notification_type", "raid"), ("join_attempts", "1200")], kind: "auto_moderation_notification"
        ))?.card)
        #expect(words(raid).contains { $0.hasPrefix("safety alert!") })
        #expect(words(raid).contains("Unusual Join Activity Detected"))
        #expect(words(raid).contains { $0.hasPrefix("~") && $0.hasSuffix(" Joins Actioned") })

        let mention = try #require(row(autoModMessage(
            [("notification_type", "mention_raid"), ("decision_id", "d1")], kind: "auto_moderation_notification"
        ))?.card)
        #expect(!words(mention).contains { $0.hasPrefix("safety alert!") })
        #expect(words(mention).contains("We're restricting some messages due to a potential mention raid."))
        #expect(actions(mention) == [.removeMentionRestrictions(decisionID: "d1"), .configureAutoMod])
    }

    @Test("A policy notice in the system DM is Discord's card, and opens as a whole")
    func safetyNotice() throws {
        let message = Message(
            id: MessageID(rawValue: 1 << 40),
            channelID: ChannelID(rawValue: 99),
            authorID: member,
            payload: MessagePayload(embeds: [Embed(kind: "safety_policy_notice", fields: [
                Embed.Field(name: "classification_id", value: "c1", isInline: false),
                Embed.Field(name: "incident_time", value: String(Int(Date.now.timeIntervalSince1970)), isInline: false),
            ])])
        )
        let laid = try #require(row(message))
        let card = try #require(laid.card)
        #expect(words(card).contains("You broke Discord's community guidelines"))
        #expect(words(card).contains("Today"))
        #expect(words(card).contains("We've taken action that affects your account."))
        #expect(actions(card) == [.accountStanding, .accountStanding])
        // Never an embed card as well.
        #expect(laid.embeds.isEmpty)
    }
}
