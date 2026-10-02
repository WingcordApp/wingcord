import Foundation
import Testing
import WingcordCore
import WingcordNet
@testable import Wingcord

/// Topics: when they are asked for, where the reader is among them, what the
/// minimap shows, and what opening and putting one away does.
@Suite("Topics")
@MainActor
struct TopicTests {

    private let channel = ChannelID(rawValue: 1001)
    private let guild = GuildID(rawValue: 100)
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// A topic spanning `start ... end`.
    private func topic(_ start: UInt64, _ end: UInt64, count: Int = 5) -> ConversationTopic {
        ConversationTopic(
            id: ConversationTopicID(rawValue: start),
            title: "Topic \(start)",
            startMessageID: MessageID(rawValue: start),
            endMessageID: MessageID(rawValue: end),
            messageCount: count
        )
    }

    private func loaded(_ topics: [ConversationTopic], coversPresent: Bool = true) -> ChannelTopics {
        ChannelTopics(topics: topics, coversPresent: coversPresent, fetchedAt: now)
    }

    // MARK: When to ask

    @Test("A channel never asked asks for its newest")
    func firstAsk() {
        #expect(TopicFetchPolicy.request(anchor: nil, state: nil, now: now) == .newest)
    }

    @Test("Reading inside what is loaded asks nothing")
    func withinLoaded() {
        let state = loaded([topic(100, 150), topic(200, 250)])
        #expect(TopicFetchPolicy.request(anchor: MessageID(rawValue: 210), state: state, now: now) == nil)
        #expect(TopicFetchPolicy.request(anchor: nil, state: state, now: now) == nil)
    }

    @Test("Above the oldest loaded topic asks around the reader's place — until nothing older exists")
    func aboveLoaded() {
        var state = loaded([topic(100, 150), topic(200, 250)])
        let anchor = MessageID(rawValue: 50)
        #expect(TopicFetchPolicy.request(anchor: anchor, state: state, now: now) == .around(anchor))
        state.reachedOldest = true
        #expect(TopicFetchPolicy.request(anchor: anchor, state: state, now: now) == nil)
    }

    @Test("The present is refreshed after Discord's hour, and not before")
    func staleness() {
        let state = loaded([topic(100, 150)])
        #expect(TopicFetchPolicy.request(anchor: nil, state: state, now: now.addingTimeInterval(1800)) == nil)
        #expect(
            TopicFetchPolicy.request(anchor: nil, state: state, now: now.addingTimeInterval(3601))
                == .after(ConversationTopicID(rawValue: 100))
        )
    }

    @Test("Nothing is asked while a page is out, or where topics were refused")
    func guards() {
        var state = loaded([])
        state.isLoading = true
        #expect(TopicFetchPolicy.request(anchor: nil, state: state, now: now) == nil)
        state.isLoading = false
        state.isUnavailable = true
        #expect(TopicFetchPolicy.request(anchor: nil, state: state, now: now.addingTimeInterval(9999)) == nil)
    }

    @Test("A page around a place replaces the list, keeps the open topic, and reads both ends")
    func aroundReplaces() {
        let open = topic(9000, 9100)
        let starts: [UInt64] = [1000, 1100, 1200, 1300, 1400]
        let answer = starts.map { start in topic(start, start + 50) }
        let next = TopicFetchPolicy.applying(
            .around(MessageID(rawValue: 1250)),
            answer: answer,
            to: loaded([topic(100, 150)]),
            keeping: open,
            now: now
        )
        let ids: [UInt64] = next.topics.map { $0.id.rawValue }
        #expect(ids == [1000, 1100, 1200, 1300, 1400, 9000])
        // Three older and two newer than the place: short of half a page on
        // both sides, so both ends were reached.
        #expect(next.reachedOldest)
        #expect(next.coversPresent)
        #expect(!next.isLoading)
    }

    // MARK: Where the reader is

    @Test("The reader is in the last topic to begin at or above their place")
    func place() {
        let topics = [topic(100, 150), topic(200, 250), topic(300, 350)]
        #expect(TopicPlace(anchor: MessageID(rawValue: 260), topics: topics).index == 1)
        #expect(TopicPlace(anchor: MessageID(rawValue: 260), topics: topics).relation == .withinLoaded)
        #expect(TopicPlace(anchor: MessageID(rawValue: 50), topics: topics).index == 0)
        #expect(TopicPlace(anchor: MessageID(rawValue: 50), topics: topics).relation == .beforeLoaded)
        #expect(TopicPlace(anchor: MessageID(rawValue: 900), topics: topics).relation == .afterLoaded)
        // At the present: the newest.
        #expect(TopicPlace(anchor: nil, topics: topics) == TopicPlace.init(anchor: nil, topics: topics))
        #expect(TopicPlace(anchor: nil, topics: topics).index == 2)
        #expect(TopicPlace(anchor: nil, topics: []).index == nil)
    }

    // MARK: The minimap

    @Test("Seven slots, centred on the reader — and six at the newest, as Discord shows")
    func window() {
        let middle = TopicMinimapWindow(count: 20, current: 10)
        #expect(middle.entries.map(\.index) == Array(7...13))
        #expect(middle.entries.map(\.slot) == Array(0...6))
        #expect(middle.fadesTop && middle.fadesBottom)

        let newest = TopicMinimapWindow(count: 20, current: 19)
        // Clamped two from the end: the last slot is empty.
        #expect(newest.entries.map(\.index) == Array(14...19))
        #expect(newest.entries.map(\.slot) == Array(0...5))
        #expect(newest.fadesTop)
        #expect(!newest.fadesBottom)

        let few = TopicMinimapWindow(count: 2, current: 1)
        #expect(few.entries.map(\.index) == [0, 1])
        #expect(!few.fadesTop && !few.fadesBottom)
    }

    // MARK: Opening one

    private func model() -> AppModel {
        let model = AppModel()
        model.guilds = [
            guild: Guild(
                id: guild, name: "CS", ownerID: UserID(rawValue: 2),
                features: [AppModel.topicsFeature]
            ),
        ]
        var index = ChannelIndex()
        index.replaceChannels(
            [Channel(id: channel, kind: .text, guildID: guild, name: "general")],
            inGuild: guild
        )
        model.channelIndex = index
        return model
    }

    @Test("Topics apply to a text channel of a server that has them, and nowhere else")
    func gate() {
        let model = model()
        #expect(model.topicsApply(to: channel))
        model.guilds[guild]?.features = []
        #expect(!model.topicsApply(to: channel))
    }

    @Test("Escape puts the panel away before it does anything else, and leaves the marker")
    func escapeClosesThePanel() {
        let model = model()
        model.openTopic = OpenTopic(channelID: channel, topic: topic(100, 150), showsPanel: true)
        #expect(model.escapeTranscript(in: channel))
        #expect(model.openTopic?.showsPanel == false)
        // With the panel away and the transcript at the present, Escape is
        // somebody else's.
        #expect(!model.escapeTranscript(in: channel))

        model.reopenTopicPanel()
        #expect(model.openTopic?.showsPanel == true)
        model.clearOpenTopic(in: channel)
        #expect(model.openTopic == nil)
    }

    @Test("A title rested on twice asks for its preview once")
    func previewAsksOnce() {
        let model = model()
        var requests: [TopicRequest] = []
        model.topicLoader = { _, request in requests.append(request) }
        let rested = topic(100, 150)
        model.previewTopic(rested, in: channel)
        model.previewTopic(rested, in: channel)
        #expect(requests == [.preview(rested.id)])
    }

    @Test("Topic messages are bounded, and the open topic's are never what goes")
    func cacheBound() {
        let model = model()
        let open = topic(1, 2)
        model.openTopic = OpenTopic(channelID: channel, topic: open, showsPanel: true)
        model.storeTopicMessages([], for: open.id, whole: true)
        for id in UInt64(10)..<UInt64(10 + AppModel.topicCacheLimit + 5) {
            model.storeTopicMessages([], for: ConversationTopicID(rawValue: id), whole: false)
        }
        #expect(model.topicCacheOrder.count == AppModel.topicCacheLimit)
        #expect(model.topicMessages[open.id] != nil)
        #expect(model.topicPreviews[ConversationTopicID(rawValue: 10)] == nil)
    }

    @Test("A topic's panel is cut into cards only where a run begins")
    func excerpts() {
        let author = { (id: UInt64) in UserID(rawValue: id % 2 == 0 ? 1 : 2) }
        // Alternating authors a second apart: every message heads its own run.
        let messages = (1...30).map { index in
            Message(
                id: MessageID(rawValue: (UInt64(index) * 1000) << 22),
                channelID: channel,
                authorID: author(UInt64(index / 3)),
                content: "line \(index)"
            )
        }
        let cards = MessageCard.excerpts(
            of: messages,
            rowsPerCard: 12,
            width: 500,
            engine: TimelineLayoutEngine(presentationRevision: 0),
            style: MessageTextStyle.current(),
            settings: PresentationRevision.shared.timeline,
            mentions: MentionContext(),
            mentionedIDs: [],
            channelName: "general",
            authors: [:]
        )
        #expect(cards.count > 1)
        // Every message is in exactly one card, in order.
        let drawn = cards.flatMap(\.messageRows).map(\.id)
        #expect(drawn == messages.map(\.id))
        // No card opens on a message that continues somebody's run.
        for card in cards.dropFirst() {
            #expect(card.messageRows.first?.hasAuthorLine == true)
        }
    }
}
