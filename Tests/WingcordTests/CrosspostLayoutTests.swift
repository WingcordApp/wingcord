import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Wingcord
@testable import WingcordCore

/// A crosspost through the real layout: no quote over it — its reference is
/// where it was published — and Discord's SERVER beside its name.
@MainActor
@Suite("Crossposts in the transcript")
struct CrosspostLayoutTests {
    private let publisher = UserID(rawValue: 5)

    private func rows(_ message: Message, postOwner: UserID? = nil) -> [TimelineRow] {
        var cache: [MessageID: TimelineLayoutEngine.CacheEntry] = [:]
        return TimelineLayoutEngine(presentationRevision: 1).layout(
            TimelineLayoutEngine.Input(
                items: [.message(TimelineMessage(message: message, flags: [.head, .tail]))],
                width: 720,
                style: MessageTextStyle.current(),
                mentions: MentionContext(),
                channelName: "news",
                postOwnerID: postOwner,
                authors: [publisher: TimelineLayoutEngine.AuthorInfo(
                    name: "Wingcord #announcements", colorValue: nil, avatarURL: nil,
                    monogram: "W", decorationURL: nil, isBot: true
                )],
                calendar: .current,
                settings: PresentationRevision.shared.timeline
            ),
            cache: &cache
        )
    }

    private func row(_ rows: [TimelineRow]) -> MessageRow? {
        rows.lazy.compactMap { if case .message(let row) = $0.kind { row } else { nil } }.first
    }

    @Test("A crosspost wears SERVER and draws no reply quote")
    func crosspost() throws {
        let message = Message(
            id: MessageID(rawValue: 1 << 30),
            channelID: ChannelID(rawValue: 3),
            authorID: publisher,
            content: "Release notes",
            flags: .isCrosspost,
            payload: MessagePayload(reference: MessageReference(
                messageID: MessageID(rawValue: 9), channelID: ChannelID(rawValue: 8), guildID: GuildID(rawValue: 77)
            ))
        )
        let laid = try #require(row(rows(message)))
        #expect(laid.authorTag == .server)
        #expect(laid.isCrosspost)
        #expect(laid.replyHeader == nil)
    }

    @Test("Discord names a crosspost's server from its publisher, less the channel")
    func publisherName() {
        #expect(AppModel.publisherName("Wingcord #announcements") == "Wingcord")
        #expect(AppModel.publisherName("Solo") == "Solo")
    }
}
