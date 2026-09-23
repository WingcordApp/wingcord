import Foundation
import WingcordCore
import WingcordNet

// MARK: - Topics
//
// Discord's conversations: stretches of a channel it has titled, drawn as a
// minimap at the transcript's trailing edge. What is fetched and when is
// Discord's own pager (module `185522`) made cheaper — see `TopicFetchPolicy`.

/// One channel's topics, and what is known about the ones not loaded.
struct ChannelTopics: Equatable, Sendable {
    /// Oldest first, by where each begins.
    var topics: [ConversationTopic] = []
    /// Whether the newest topic is among them — true after a fetch of the
    /// newest, false after one around a message far back.
    var coversPresent = false
    /// Whether nothing older exists: the last look back came up short.
    var reachedOldest = false
    /// When the list was last answered, for Discord's hour of staleness.
    var fetchedAt: Date?
    var isLoading = false
    /// The server does not offer topics here, or refused: draw nothing, and
    /// do not ask again this session.
    var isUnavailable = false
}

/// Where a reader is among a channel's topics.
///
/// **What a scroll has to cross to be worth reporting.** The index moves only
/// at a topic's start, and the relation only when the reader's place leaves the
/// loaded list — so the minimap re-centres, and the store is asked for more
/// topics, a handful of times per channel rather than on every tick.
nonisolated struct TopicPlace: Equatable, Sendable {
    enum Relation: Equatable, Sendable {
        /// At the channel's foot, reading the present.
        case present
        /// Above where the oldest loaded topic begins.
        case beforeLoaded
        case withinLoaded
        /// Below where the newest loaded topic ends.
        case afterLoaded
    }

    /// The topic the reader is in — the last to begin at or above their place,
    /// or the first when none has; the newest when they are at the present.
    /// Nil when there are no topics. Discord's own rule (module `247933`).
    var index: Int?
    var relation: Relation

    init(anchor: MessageID?, topics: [ConversationTopic]) {
        guard let anchor else {
            index = topics.isEmpty ? nil : topics.count - 1
            relation = .present
            return
        }
        if let first = topics.first, anchor.rawValue < first.startMessageID.rawValue {
            relation = .beforeLoaded
        } else if let last = topics.last, anchor.rawValue > last.endMessageID.rawValue {
            relation = .afterLoaded
        } else {
            relation = .withinLoaded
        }
        guard !topics.isEmpty else {
            index = nil
            return
        }
        index = topics.lastIndex { $0.startMessageID.rawValue <= anchor.rawValue } ?? 0
    }
}

/// The topic marked in the transcript.
struct OpenTopic: Equatable, Sendable {
    var channelID: ChannelID
    var topic: ConversationTopic
    /// Whether its panel — the topic's messages, over the transcript — is up.
    /// Closing it leaves the marker, which is how the panel is found again.
    var showsPanel: Bool
}

/// What the store asks the session for.
enum TopicRequest: Equatable, Sendable {
    /// A page of the channel's topics.
    case list(DiscordREST.TopicPage)
    /// A topic's first messages, for its preview.
    case preview(ConversationTopicID)
    /// All of a topic's messages, for its panel.
    case whole(ConversationTopicID)
}

/// When to ask for topics, and which.
///
/// **Discord's pager, without its chatter.** Discord refetches the list around
/// the newest message whenever the reader returns to it, and keeps ten topics
/// buffered on both sides of wherever they are — eight fetches of the same
/// thirteen topics in a two-minute capture. Here a list is asked for only when
/// the reader's place leaves what is loaded, or when an hour (Discord's own
/// staleness, `sE`) has passed since the newest were asked for.
nonisolated enum TopicFetchPolicy {
    static let staleAfter: TimeInterval = 3600
    /// About half a page lands either side of an `around` anchor; fewer than
    /// this on one side means that end of the channel was reached.
    static let halfPage = DiscordREST.topicPageSize / 2

    /// - Parameter anchor: the message at the top of the viewport, or nil when
    ///   the reader is at the present.
    static func request(
        anchor: MessageID?,
        state: ChannelTopics?,
        now: Date
    ) -> DiscordREST.TopicPage? {
        guard let state else { return .newest }
        guard !state.isLoading, !state.isUnavailable else { return nil }
        let isStale = state.fetchedAt.map { now.timeIntervalSince($0) > staleAfter } ?? true
        guard let first = state.topics.first, let last = state.topics.last else {
            // Asked, and none: the channel has not been summarised yet.
            return isStale ? .newest : nil
        }
        guard let anchor else {
            if !state.coversPresent { return .newest }
            return isStale ? .after(last.id) : nil
        }
        if anchor.rawValue < first.startMessageID.rawValue {
            return state.reachedOldest ? nil : .around(anchor)
        }
        if anchor.rawValue > last.endMessageID.rawValue, !state.coversPresent {
            return .around(anchor)
        }
        return nil
    }

    /// The list once a page has landed.
    static func applying(
        _ page: DiscordREST.TopicPage,
        answer: [ConversationTopic],
        to state: ChannelTopics,
        keeping open: ConversationTopic?,
        now: Date
    ) -> ChannelTopics {
        var next = state
        next.isLoading = false
        next.fetchedAt = now
        switch page {
        case .newest:
            next.topics = answer
            next.coversPresent = true
            next.reachedOldest = answer.count < DiscordREST.topicPageSize
        case .after:
            next.topics = merged(state.topics, answer)
            // A full page may not be all of them; the next look at the present
            // asks for the newest instead.
            next.coversPresent = answer.count < DiscordREST.topicPageSize
        case .around(let anchor):
            // **Replaced, not merged** — Discord's own jump rule — so the list
            // never runs from last year straight into today with nothing to
            // say what lies between. The open topic is kept, or its marker
            // would lose the topic it belongs to.
            next.topics = merged(open.map { [$0] } ?? [], answer)
            let older = answer.count(where: { $0.startMessageID.rawValue < anchor.rawValue })
            next.reachedOldest = older < halfPage
            next.coversPresent = answer.count - older < halfPage
        }
        return next
    }

    private static func merged(
        _ held: [ConversationTopic],
        _ answer: [ConversationTopic]
    ) -> [ConversationTopic] {
        var byID: [ConversationTopicID: ConversationTopic] = [:]
        for topic in held { byID[topic.id] = topic }
        for topic in answer { byID[topic.id] = topic }
        return byID.values.sorted { $0.startMessageID.rawValue < $1.startMessageID.rawValue }
    }
}

extension AppModel {

    /// Discord's guild flag for a server whose conversations are summarised.
    static let topicsFeature = "CONVERSATIONS_EXTRACTION_PROCESSING"
    /// How many topics' messages are kept, previews and panels together.
    static let topicCacheLimit = 32

    /// Whether this channel can have topics.
    ///
    /// **The server's flag, and nothing about the reader.** Discord also gates
    /// on three experiments (module `828488`) that this client cannot evaluate,
    /// so a server that has the flag is asked once; a refusal or an empty
    /// answer is remembered, and costs nothing after that.
    func topicsApply(to channelID: ChannelID) -> Bool {
        guard let channel = channelIndex[channelID],
              channel.kind == .text || channel.kind == .announcement,
              let guildID = channel.guildID
        else { return false }
        return guilds[guildID]?.features.contains(Self.topicsFeature) == true
    }

    /// Asks for whichever topics the reader's place needs, if any.
    func loadTopicsIfNeeded(in channelID: ChannelID, anchor: MessageID?) {
        guard topicsApply(to: channelID),
              let page = TopicFetchPolicy.request(
                  anchor: anchor, state: conversationTopics[channelID], now: .now
              ),
              let topicLoader
        else { return }
        conversationTopics[channelID, default: ChannelTopics()].isLoading = true
        topicLoader(channelID, .list(page))
    }

    /// A page of topics landed.
    func applyTopics(
        _ answer: [ConversationTopic],
        for page: DiscordREST.TopicPage,
        in channelID: ChannelID
    ) {
        let open = openTopic.flatMap { $0.channelID == channelID ? $0.topic : nil }
        conversationTopics[channelID] = TopicFetchPolicy.applying(
            page,
            answer: answer,
            to: conversationTopics[channelID] ?? ChannelTopics(),
            keeping: open,
            now: .now
        )
    }

    /// A page of topics did not land. A refusal is final for the session; a
    /// dropped connection lets the next change of place ask again.
    func failTopics(in channelID: ChannelID, refused: Bool) {
        conversationTopics[channelID, default: ChannelTopics()].isLoading = false
        if refused { conversationTopics[channelID]?.isUnavailable = true }
    }

    /// Fetches a topic's preview, unless it is already held.
    func previewTopic(_ topic: ConversationTopic, in channelID: ChannelID) {
        guard topicPreviews[topic.id] == nil, topicMessages[topic.id] == nil,
              topicFetchesInFlight.insert(topic.id).inserted
        else { return }
        topicLoader?(channelID, .preview(topic.id))
    }

    /// A topic's first messages, for its preview: the preview's own answer, or
    /// the head of the whole topic when that is already held.
    func topicPreview(_ topicID: ConversationTopicID) -> [Message]? {
        topicPreviews[topicID] ?? topicMessages[topicID].map { Array($0.prefix(4)) }
    }

    /// Stores a topic's messages, keeping the two tables bounded together.
    func storeTopicMessages(_ messages: [Message], for topicID: ConversationTopicID, whole: Bool) {
        if whole {
            topicMessages[topicID] = messages
            topicPreviews[topicID] = nil
        } else {
            topicPreviews[topicID] = messages
        }
        topicCacheOrder.removeAll { $0 == topicID }
        topicCacheOrder.append(topicID)
        while topicCacheOrder.count > Self.topicCacheLimit {
            let evicted = topicCacheOrder.removeFirst()
            // The open topic's messages are on screen; they are never the ones
            // that go.
            guard evicted != openTopic?.topic.id else {
                topicCacheOrder.append(evicted)
                continue
            }
            topicPreviews[evicted] = nil
            topicMessages[evicted] = nil
        }
    }

    /// Opens a topic: the transcript goes to where it begins, its marker goes
    /// above that message, and its panel comes up over the transcript.
    ///
    /// Discord's `selectAndFocusConversation` (module `247933`): the jump is
    /// made without the landing flash, because the marker is the landing mark.
    func openTopic(_ topic: ConversationTopic, in channelID: ChannelID) {
        openTopic = OpenTopic(channelID: channelID, topic: topic, showsPanel: true)
        // A preview in flight is not the whole topic, so the in-flight set is
        // not consulted here: the whole answer supersedes it when it lands.
        if topicMessages[topic.id] == nil { topicLoader?(channelID, .whole(topic.id)) }
        sessionController.jumpToMessage(topic.startMessageID, in: channelID, highlights: false)
    }

    /// Takes the panel down and leaves the marker — Discord's "return".
    func closeTopicPanel() {
        guard openTopic?.showsPanel == true else { return }
        openTopic?.showsPanel = false
    }

    /// The marker was clicked: its panel comes back.
    func reopenTopicPanel() {
        guard openTopic?.showsPanel == false else { return }
        openTopic?.showsPanel = true
    }

    /// Forgets the open topic — its marker scrolled away, or the reader left.
    func clearOpenTopic(in channelID: ChannelID) {
        guard openTopic?.channelID == channelID else { return }
        openTopic = nil
    }
}

// MARK: - Drawn

/// What a topic's laid-out cards were built against.
struct TopicCardKey: Hashable, Sendable {
    var topicID: ConversationTopicID
    var width: CGFloat
    var revision: UInt64
}

extension AppModel {
    /// Rows per card in the panel — see `MessageCard.excerpts`.
    static let topicRowsPerCard = 12

    /// The open topic's messages, laid out as the panel draws them.
    ///
    /// **Memoized, for `pinnedCards`' reason**: a layout is framesetting, and
    /// the panel's body runs again on every hover inside it. The key carries
    /// the messages themselves, not a count, so a reaction landing lays the
    /// cards out again — §2's trap with the transcript's first cache.
    func topicCards(
        for topicID: ConversationTopicID,
        in channelID: ChannelID,
        width: CGFloat
    ) -> [MessageCard] {
        // Read before the early return, so a hit still registers the
        // dependency — §2.
        let messages = topicMessages[topicID] ?? []
        let key = TopicCardKey(topicID: topicID, width: width, revision: PresentationRevision.shared.value)
        if let topicCardCache, topicCardCache.key == key, topicCardCache.messages == messages {
            return topicCardCache.value
        }
        let value = layOut(messages, in: channelID, width: width, key: key) { input in
            MessageCard.excerpts(
                of: messages,
                rowsPerCard: Self.topicRowsPerCard,
                width: width,
                engine: input.engine,
                style: input.style,
                settings: input.settings,
                mentions: input.mentions,
                mentionedIDs: mentionableIDs,
                channelName: input.channelName,
                authors: input.authors
            )
        } ?? []
        topicCardCache = (key, messages, value)
        return value
    }

    /// A topic's preview, laid out as one excerpt.
    func topicPreviewCard(
        for topicID: ConversationTopicID,
        in channelID: ChannelID,
        width: CGFloat
    ) -> MessageCard? {
        let messages = topicPreview(topicID) ?? []
        let key = TopicCardKey(topicID: topicID, width: width, revision: PresentationRevision.shared.value)
        if let topicPreviewCardCache,
           topicPreviewCardCache.key == key,
           topicPreviewCardCache.messages == messages
        {
            return topicPreviewCardCache.value
        }
        let value = layOut(messages, in: channelID, width: width, key: key) { input in
            MessageCard.excerpt(
                of: messages,
                unreadAnchor: nil,
                width: width,
                engine: input.engine,
                style: input.style,
                settings: input.settings,
                mentions: input.mentions,
                mentionedIDs: mentionableIDs,
                channelName: input.channelName,
                authors: input.authors
            )
        } ?? nil
        topicPreviewCardCache = (key, messages, value)
        return value
    }

    /// What every card layout needs, resolved once per build.
    private struct CardInput {
        var engine: TimelineLayoutEngine
        var style: MessageTextStyle
        var settings: TimelineSettings
        var mentions: MentionContext
        var channelName: String
        var authors: [UserID: TimelineLayoutEngine.AuthorInfo]
    }

    private func layOut<Value>(
        _ messages: [Message],
        in channelID: ChannelID,
        width: CGFloat,
        key: TopicCardKey,
        build: (CardInput) -> Value
    ) -> Value? {
        guard !messages.isEmpty else { return nil }
        let style = PresentationRevision.shared.style
        let items = messages.map {
            TimelineItem.message(TimelineMessage(message: $0, flags: [.head, .tail]))
        }
        return build(CardInput(
            engine: TimelineLayoutEngine(presentationRevision: key.revision),
            style: style,
            settings: PresentationRevision.shared.timeline,
            mentions: mentionContext(),
            channelName: channelIndex[channelID].map(displayName(of:)) ?? "",
            authors: authorInfo(
                for: items,
                inGuild: channelIndex.guildID(of: channelID),
                authorFont: style.authorFont
            )
        ))
    }
}
