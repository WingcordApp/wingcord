import Foundation
import WingcordCore

/// The demo's search: Discord's answer worked out from the messages the demo
/// already holds.
///
/// **A demo launch has no token, and the real route answers it 401**, so the
/// results panel — its tabs and their counts, its page pill and Go to Page,
/// its filter tokens — could only ever be looked at empty. This answers the
/// same question the same way the tabs route does: every tab counted, the tab
/// on show paged, the question's own `has` winning over the tab's.
///
/// Only `--demo` reaches it (`SessionController.searchPage`).
enum DemoSearch {

    @MainActor
    static func page(for query: MessageSearchQuery, in model: AppModel) -> MessageSearchPage {
        let channels: [ChannelID]
        switch query.scope {
        case .guild(let guildID):
            let all = model.channelIndex.channelIDs(inGuild: guildID)
            channels = query.channelIDs.isEmpty ? all : all.filter { query.channelIDs.contains($0) }
        case .channel(let channelID):
            channels = [channelID]
        }
        let pool = channels.flatMap { model.messages(in: $0)?.messages ?? [] }

        var counts: [MessageSearchTab: Int] = [:]
        var shown: [Message] = []
        for tab in MessageSearchTab.allCases {
            var asked = query
            asked.tab = tab
            let hits = pool.filter { matches($0, asked) }
            counts[tab] = hits.count
            if tab == query.tab { shown = hits }
        }
        // Newest first unless the question asked for the oldest; relevance has
        // nothing to rank by here and falls back to the newest.
        let ascending = query.sort == .timestamp && query.order == .ascending
        shown.sort { ascending ? $0.id < $1.id : $0.id > $1.id }

        let onPage = Array(shown.dropFirst(query.offset).prefix(MessageSearchQuery.pageSize))
        var authors: [UserID: User] = [:]
        for message in onPage {
            if let user = model.users[message.authorID] { authors[message.authorID] = user }
        }
        return MessageSearchPage(
            messages: onPage,
            totalResults: shown.count,
            isDeepIndexing: false,
            authors: authors,
            tabCounts: counts
        )
    }

    /// Whether a message answers the question, as the route reads it: every
    /// field narrows, and a list within a field is any of its values.
    static func matches(_ message: Message, _ query: MessageSearchQuery) -> Bool {
        let words = query.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !words.isEmpty, !message.content.localizedCaseInsensitiveContains(words) { return false }
        if !query.authorIDs.isEmpty, !query.authorIDs.contains(message.authorID) { return false }
        if !query.mentionIDs.isEmpty, !query.mentionIDs.contains(where: message.mentionedUserIDs.contains) {
            return false
        }
        if let pinned = query.isPinned, message.isPinned != pinned { return false }
        let bounds = query.dateBounds
        if let after = bounds.after, message.sentAt < after { return false }
        if let before = bounds.before, message.sentAt >= before { return false }
        let has = query.tabHas
        if !has.isEmpty, !has.contains(where: { holds(message, $0) }) { return false }
        return true
    }

    static func holds(_ message: Message, _ kind: MessageSearchHas) -> Bool {
        switch kind {
        case .image: message.attachments.contains(where: \.isImage)
        case .video: message.attachments.contains(where: \.isVideo)
        case .sound: message.attachments.contains { $0.contentType?.hasPrefix("audio/") ?? false }
        case .file: !message.attachments.isEmpty
        case .link: message.content.contains("http://") || message.content.contains("https://")
        case .embed: !message.embeds.isEmpty
        case .sticker: !message.stickers.isEmpty
        case .poll: message.poll != nil
        case .snapshot: message.forwarded != nil
        }
    }
}
