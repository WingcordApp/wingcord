import Foundation
import WingcordCore

/// One filter the results on screen were searched with, shown under the
/// panel's header and taken off with its ✕.
struct SearchFilterToken: Hashable, Sendable, Identifiable {
    enum Kind: Hashable, Sendable {
        case from(UserID)
        case mentions(UserID)
        case channel(ChannelID)
        case has(MessageSearchHas)
        case author(MessageSearchAuthorKind)
        case pinned
        case date(Int)
    }

    var kind: Kind
    /// "From", "In", "Has", "Before"…
    var prefix: String
    /// The person, the channel, the kind, the day.
    var value: String
    var avatarURL: URL?
    var monogram: String?
    var symbolName: String?

    var id: Kind { kind }
}

extension AppModel {

    /// The filters the results were searched with — the SUBMITTED query, not
    /// what is being typed: a token says what the list under it is.
    var searchFilterTokens: [SearchFilterToken] {
        guard let query = messageSearch?.submitted else { return [] }
        var tokens: [SearchFilterToken] = []
        for id in query.authorIDs {
            tokens.append(personToken(.from(id), prefix: "From", id: id))
        }
        for id in query.mentionIDs {
            tokens.append(personToken(.mentions(id), prefix: "Mentions", id: id))
        }
        for id in query.channelIDs {
            let channel = channelIndex[id]
            tokens.append(SearchFilterToken(
                kind: .channel(id),
                prefix: "In",
                value: channel.map(displayName(of:)) ?? "a channel",
                symbolName: channel.map(channelSymbol(of:)) ?? "number"
            ))
        }
        for has in query.has.sorted(by: { $0.rawValue < $1.rawValue }) {
            tokens.append(SearchFilterToken(
                kind: .has(has), prefix: "Has", value: has.title, symbolName: has.symbolName
            ))
        }
        for kind in query.authorKinds.sorted(by: { $0.rawValue < $1.rawValue }) {
            tokens.append(SearchFilterToken(
                kind: .author(kind), prefix: "Author", value: kind.title, symbolName: kind.symbolName
            ))
        }
        if let isPinned = query.isPinned {
            tokens.append(SearchFilterToken(
                kind: .pinned,
                prefix: "Pinned",
                value: isPinned ? "Yes" : "No",
                symbolName: isPinned ? "pin.fill" : "pin.slash"
            ))
        }
        for (index, date) in query.dates.enumerated() {
            tokens.append(SearchFilterToken(
                kind: .date(index),
                prefix: date.title,
                value: date.day.formatted(.dateTime.day().month(.abbreviated).year()),
                symbolName: "calendar"
            ))
        }
        return tokens
    }

    private func personToken(_ kind: SearchFilterToken.Kind, prefix: String, id: UserID) -> SearchFilterToken {
        let user = users[id]
        return SearchFilterToken(
            kind: kind,
            prefix: prefix,
            value: user?.preferredName ?? "someone",
            avatarURL: user.flatMap { avatarURL(for: $0, side: 18) },
            monogram: user?.monogram ?? "?"
        )
    }

    /// Searches again without one filter — written back into the field the way
    /// the sheet writes its answer, since the field is the query.
    func removeSearchFilter(_ token: SearchFilterToken) {
        guard var query = messageSearch?.submitted else { return }
        switch token.kind {
        case .from(let id): query.authorIDs.removeAll { $0 == id }
        case .mentions(let id): query.mentionIDs.removeAll { $0 == id }
        case .channel(let id): query.channelIDs.removeAll { $0 == id }
        case .has(let has): query.has.remove(has)
        case .author(let kind): query.authorKinds.remove(kind)
        case .pinned: query.isPinned = nil
        case .date(let index):
            guard query.dates.indices.contains(index) else { return }
            query.dates.remove(at: index)
        }
        applySearchFilters(query)
    }
}
