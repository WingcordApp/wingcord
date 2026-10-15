import Foundation
import WingcordCore
import WingcordNet

/// What one of the inspector's tabs lists (REDESIGN.md R11).
enum LibraryKind: Hashable, Sendable, CaseIterable {
    case media
    case links
    case files

    /// The search filters that find it, one query each: Discord's `has` is a
    /// filter on the message, and pictures and videos are two of them.
    var filters: [MessageSearchHas] {
        switch self {
        case .media: [.image, .video]
        case .links: [.link]
        case .files: [.file]
        }
    }
}

struct LibraryArchiveKey: Hashable, Sendable {
    var channelID: ChannelID
    var kind: LibraryKind
}

/// The older half of an inspector tab: what search found further back than the
/// loaded transcript reaches, page by page, newest first.
struct LibraryArchive: Sendable {
    var messages: [Message] = []
    /// The search page the next request asks for — every filter of the kind
    /// is asked for the same page.
    var nextPage = 1
    /// The filters with nothing older left.
    var exhausted: Set<MessageSearchHas> = []
    var isLoading = false
    /// Why the last page did not come, said under the list.
    var failure: String?

    func isExhausted(for kind: LibraryKind) -> Bool {
        kind.filters.allSatisfy(exhausted.contains)
    }

    /// Folds a page in: each message once, newest first.
    mutating func receive(_ page: [Message]) {
        var seen = Set(messages.map(\.id))
        messages += page.filter { seen.insert($0.id).inserted }
        messages.sort { $0.id.rawValue > $1.id.rawValue }
    }
}

extension AppModel {
    /// A message this client holds for `channelID`: in its transcript, or found
    /// for its inspector by search.
    func knownMessage(_ messageID: MessageID, in channelID: ChannelID) -> Message? {
        if let message = messageBoxes[channelID]?.messages.first(where: { $0.id == messageID }) {
            return message
        }
        for kind in LibraryKind.allCases {
            let key = LibraryArchiveKey(channelID: channelID, kind: kind)
            if let message = libraryArchives[key]?.messages.first(where: { $0.id == messageID }) {
                return message
            }
        }
        return nil
    }
}

extension SessionController {
    /// The next page of a conversation's older media, links or files — Discord's
    /// message search narrowed to the conversation and to what the tab lists
    /// (`has=image|video`, `has=link`, `has=file`), newest first.
    ///
    /// **One query per filter, one after another**: search is the most
    /// tightly limited route Discord has, and two at once would only queue in
    /// the limiter. A 202 — the index still being built — waits as long as it
    /// asks, up to three times, before saying so.
    func loadLibraryPage(in channelID: ChannelID, kind: LibraryKind) {
        let key = LibraryArchiveKey(channelID: channelID, kind: kind)
        var archive = model.libraryArchives[key] ?? LibraryArchive()
        guard !archive.isLoading, !archive.isExhausted(for: kind) else { return }
        let channel = model.channelIndex[channelID]
        let scope: MessageSearchScope
        if channel?.kind.isPrivate == true {
            scope = .channel(channelID)
        } else if let guildID = channel?.guildID {
            scope = .guild(guildID)
        } else {
            // Nowhere to search: the tab has what the transcript has, and says
            // so rather than waiting on a request that will never go.
            archive.exhausted = Set(kind.filters)
            model.libraryArchives[key] = archive
            return
        }
        archive.isLoading = true
        archive.failure = nil
        model.libraryArchives[key] = archive
        let page = archive.nextPage
        let filters = kind.filters.filter { !archive.exhausted.contains($0) }

        Task { [weak self] in
            guard let self else { return }
            var found: [Message] = []
            var exhausted: Set<MessageSearchHas> = []
            var failure: String?
            for filter in filters {
                var query = MessageSearchQuery(scope: scope)
                if scope.guildID != nil { query.channelIDs = [channelID] }
                query.has = [filter]
                query.page = page
                do {
                    let result = try await searchWaitingForIndex(query)
                    found += result.messages
                    model.users.merge(result.authors) { existing, new in new.merged(over: existing) }
                    if result.messages.count < MessageSearchQuery.pageSize || page >= MessageSearchQuery.maximumPage {
                        exhausted.insert(filter)
                    }
                } catch {
                    Self.trace("library \(kind) \(channelID) page \(page) failed: \(Self.describe(error))")
                    failure = Self.describe(error)
                    break
                }
            }
            var archive = model.libraryArchives[key] ?? LibraryArchive()
            archive.isLoading = false
            if let failure {
                archive.failure = failure
            } else {
                archive.receive(found)
                archive.exhausted.formUnion(exhausted)
                archive.nextPage = page + 1
                if !found.isEmpty { model.identityRevision &+= 1 }
            }
            model.libraryArchives[key] = archive
        }
    }

    private func searchWaitingForIndex(_ query: MessageSearchQuery) async throws -> MessageSearchPage {
        var attempts = 0
        while true {
            do {
                return try await rest.searchMessages(query)
            } catch let indexing as DiscordREST.SearchIndexing where attempts < 3 {
                attempts += 1
                try await Task.sleep(for: indexing.delay)
            }
        }
    }
}
