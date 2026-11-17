import Foundation
import SwiftUI
import Testing
import WingcordCore

@testable import Wingcord

/// A browse row's topic: Discord's markup drawn, not printed (Alex,
/// 2026-11-17 — the list showed `**` and raw channel ids).
@MainActor
struct ChannelTopicPreviewTests {
    private func preview(_ markdown: String, mentions: MentionContext = MentionContext()) -> AttributedString {
        ChannelTopicPreview.attributed(markdown, mentions: mentions, userName: { _ in nil })
    }

    @Test("Bold and code lose their marks and keep their look")
    func markupIsDrawn() {
        let text = preview("**Read** the `rules`")
        #expect(String(text.characters) == "Read the rules")
        let bold = text.runs.first { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
        #expect(bold.map { String(text[$0.range].characters) } == "Read")
        let code = text.runs.first { $0.inlinePresentationIntent?.contains(.code) == true }
        #expect(code.map { String(text[$0.range].characters) } == "rules")
    }

    @Test("A channel mention reads as the channel's name")
    func channelMention() {
        var mentions = MentionContext()
        mentions.channels[ChannelID(rawValue: 5)] = LinkChannel(
            name: "rules", guildID: GuildID(rawValue: 1), kind: .text, canView: true, isPost: false, parentID: nil
        )
        mentions.token = 7
        #expect(String(preview("Start in <#5>", mentions: mentions).characters) == "Start in #rules")
    }

    @Test("Paragraphs and line breaks run on as one line of words")
    func newlinesCollapse() {
        #expect(String(preview("Welcome!\n\nBe kind.\nNo spam.").characters) == "Welcome! Be kind. No spam.")
    }

    @Test("A spoiler stays covered")
    func spoilerCovered() {
        let text = preview("the end is ||a twist||")
        let spoiler = text.runs.first { String(text[$0.range].characters) == "a twist" }
        #expect(spoiler?.foregroundColor == .clear)
    }
}
