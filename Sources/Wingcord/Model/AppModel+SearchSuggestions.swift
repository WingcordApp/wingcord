import Foundation
import WingcordCore

// MARK: - What the search field offers while it is being typed

/// One row of the field's suggestion list.
struct SearchSuggestion: Hashable, Sendable, Identifiable {
    /// Stable across keystrokes so the list re-orders rather than rebuilding.
    var id: String
    /// The whole field text this row would produce. `.searchCompletion` takes a
    /// string, so the completion is computed here where the tokenizer is, not
    /// in the view.
    var completion: String
    var title: String
    /// The handle under the name — `alexsample` beside `alex`.
    var detail: String?
    var avatarURL: URL?
    var monogram: String?
    var symbolName: String?
}

extension AppModel {

    /// How many rows the list offers.
    ///
    /// **Capped, and the cap is the point.** A suggestion list is scanned, not
    /// read: past about a dozen rows nobody is choosing from it, and every row
    /// past the cap is an avatar decode and a layout for something nobody sees.
    private static let suggestionLimit = 12

    /// What to offer for the text currently in the field.
    ///
    /// **Scoped to what is selected, and rebuilt when that changes.** The people
    /// are this server's members and the channels are this server's channels; in
    /// a DM they are its recipients and nothing else. Moving between servers or
    /// conversations therefore changes the list with no invalidation of its own
    /// — the projection reads `searchScope`, so Observation does it.
    func searchSuggestions(for text: String) -> [SearchSuggestion] {
        guard let scope = searchScope else { return [] }
        let parsed = MessageSearchTokenizer.parse(text)

        // Nothing being typed as a filter: offer the grammar itself, which is
        // what Discord's own field does on an empty box.
        guard let editing = parsed.editing else {
            return MessageSearchToken.Kind.allCases.compactMap { kind in
                guard kind.isOffered(in: scope) else { return nil }
                return SearchSuggestion(
                    id: "key.\(kind.rawValue)",
                    // A bare `key:` — picking it leaves the caret ready for the
                    // value, which is the whole gesture.
                    completion: appending(keyword: kind.keyword, to: text),
                    title: kind.title,
                    detail: kind.example,
                    symbolName: kind.symbolName
                )
            }
        }

        let needle = editing.value.lowercased()
        switch editing.kind.suggests {
        case .people:
            return people(in: scope, matching: needle, text: text, kind: editing.kind)
        case .channels:
            return channels(in: scope, matching: needle, text: text)
        case .hasValues:
            return MessageSearchHas.allCases
                .filter { needle.isEmpty || $0.rawValue.hasPrefix(needle) }
                .map { value in
                    completion(
                        id: "has.\(value.rawValue)",
                        token: .init(kind: .has, value: value.rawValue),
                        text: text,
                        title: value.title,
                        symbolName: value.symbolName
                    )
                }
        case .booleans:
            return ["true", "false"]
                .filter { needle.isEmpty || $0.hasPrefix(needle) }
                .map { value in
                    completion(
                        id: "pinned.\(value)",
                        token: .init(kind: .pinned, value: value),
                        text: text,
                        title: value == "true" ? "Pinned" : "Not pinned",
                        symbolName: value == "true" ? "pin.fill" : "pin.slash"
                    )
                }
        case .dates:
            // A date is typed, not chosen from a list — but the shape is worth
            // showing once, because `2026-09-07` is the only form that parses.
            guard needle.isEmpty else { return [] }
            let today = Self.dateFormatter.string(from: .now)
            return [
                completion(
                    id: "date.today",
                    token: .init(kind: editing.kind, value: today),
                    text: text,
                    title: "Today",
                    detail: today,
                    symbolName: "calendar"
                )
            ]
        }
    }

    /// The people worth offering, in the order somebody expects to find them.
    ///
    /// **A prefix match on either name, folded once.** Folding the needle per
    /// candidate is a string allocation per member per keystroke, which on a
    /// loaded roster is the difference between a list that keeps up with typing
    /// and one that does not.
    private func people(
        in scope: MessageSearchScope,
        matching needle: String,
        text: String,
        kind: MessageSearchToken.Kind
    ) -> [SearchSuggestion] {
        var rows: [SearchSuggestion] = []
        rows.reserveCapacity(Self.suggestionLimit)

        for userID in candidateUserIDs(in: scope) {
            guard let user = users[userID] else { continue }
            guard needle.isEmpty
                    || user.handle.lowercased().hasPrefix(needle)
                    || user.preferredName.lowercased().hasPrefix(needle)
            else { continue }
            rows.append(SearchSuggestion(
                id: "\(kind.rawValue).\(userID.rawValue)",
                // **The handle, never the display name.** The route matches on
                // the account, and two people can share a display name.
                completion: MessageSearchTokenizer.completing(
                    text, with: .init(kind: kind, value: user.handle)
                ),
                title: user.preferredName,
                detail: user.handle,
                avatarURL: avatarURL(for: user, side: Metrics.avatarRow),
                monogram: user.monogram
            ))
            // **Stops at the cap rather than sorting a whole roster.** The list
            // is scanned; a perfectly ranked thirteenth row is work nobody sees.
            if rows.count == Self.suggestionLimit { break }
        }
        return rows
    }

    /// Who this scope can offer.
    ///
    /// A server's loaded members, or a conversation's recipients. **The reader
    /// first**, because "from: me" is the commonest search there is.
    func candidateUserIDs(in scope: MessageSearchScope) -> [UserID] {
        var ids: [UserID] = []
        if let currentUserID { ids.append(currentUserID) }
        switch scope {
        case .guild(let guildID):
            for userID in (members[guildID] ?? [:]).keys where userID != currentUserID {
                ids.append(userID)
            }
        case .channel(let channelID):
            for userID in channelIndex[channelID]?.recipientIDs ?? [] where userID != currentUserID {
                ids.append(userID)
            }
        }
        return ids
    }

    private func channels(
        in scope: MessageSearchScope,
        matching needle: String,
        text: String
    ) -> [SearchSuggestion] {
        // A DM has one channel, and the route rejects the parameter there — so
        // the key is not offered and this is never reached with one.
        guard case .guild(let guildID) = scope else { return [] }
        var rows: [SearchSuggestion] = []
        rows.reserveCapacity(Self.suggestionLimit)

        for channelID in channelIndex.channelIDs(inGuild: guildID) {
            guard let channel = channelIndex[channelID],
                  channel.kind.isConversation,
                  // A channel the reader cannot read is a filter that returns
                  // nothing — the inert control §5.5 forbids, as a row.
                  permissionGate.canView(channelID)
            else { continue }
            let name = displayName(of: channel)
            guard needle.isEmpty || name.lowercased().hasPrefix(needle) else { continue }
            rows.append(SearchSuggestion(
                id: "in.\(channelID.rawValue)",
                completion: MessageSearchTokenizer.completing(
                    text, with: .init(kind: .channel, value: name)
                ),
                title: name,
                symbolName: channel.kind.symbolName
            ))
            if rows.count == Self.suggestionLimit { break }
        }
        return rows
    }

    // MARK: Helpers

    private func completion(
        id: String,
        token: MessageSearchToken,
        text: String,
        title: String,
        detail: String? = nil,
        symbolName: String? = nil
    ) -> SearchSuggestion {
        SearchSuggestion(
            id: id,
            completion: MessageSearchTokenizer.completing(text, with: token),
            title: title,
            detail: detail,
            symbolName: symbolName
        )
    }

    /// Appends a bare `key:` to whatever is typed, leaving the caret to fill in
    /// the value.
    private func appending(keyword: String, to text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "\(keyword): " : "\(trimmed) \(keyword): "
    }

    /// `yyyy-MM-dd`, the one form the field parses.
    ///
    /// A stored formatter rather than one per call: `DateFormatter` is expensive
    /// to build and this is reached from a keystroke path.
    nonisolated static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

private extension MessageSearchToken.Kind {
    /// Whether this key means anything here.
    ///
    /// `in:` does not: a DM has one channel and the route rejects the parameter.
    func isOffered(in scope: MessageSearchScope) -> Bool {
        self != .channel || scope.guildID != nil
    }
}

// MARK: - What the filter sheet chooses from

extension AppModel {

    /// The people the sheet can filter on, in the order the field offers them.
    ///
    /// **The same source as the field's autocomplete**, so a name that completes
    /// in one appears in the other — two different rosters for one search would
    /// be two answers to "who is here".
    var searchFilterPeople: [SearchFilterOption] {
        guard let scope = searchScope else { return [] }
        var rows: [SearchFilterOption] = []
        for id in candidateUserIDs(in: scope) {
            guard let user = users[id] else { continue }
            rows.append(SearchFilterOption(
                id: id.rawValue,
                title: user.preferredName,
                detail: user.handle,
                avatarURL: avatarURL(for: user, side: Metrics.avatarRow),
                monogram: user.monogram
            ))
            // The sheet is a menu, not a directory: past a couple of hundred
            // rows nobody scrolls it, and the field's autocomplete is the way
            // to reach somebody who is not near the top.
            if rows.count == Self.filterOptionLimit { break }
        }
        return rows
    }

    var searchFilterChannels: [SearchFilterOption] {
        guard case .guild(let guildID)? = searchScope else { return [] }
        var rows: [SearchFilterOption] = []
        for id in channelIndex.channelIDs(inGuild: guildID) {
            guard let channel = channelIndex[id],
                  channel.kind.isConversation,
                  permissionGate.canView(id)
            else { continue }
            rows.append(SearchFilterOption(
                id: id.rawValue,
                title: displayName(of: channel),
                symbolName: channel.kind.symbolName
            ))
            if rows.count == Self.filterOptionLimit { break }
        }
        return rows
    }

    private static let filterOptionLimit = 200

    /// The query the sheet opens on — the field, parsed.
    var searchFilterQuery: MessageSearchQuery {
        resolvedQuery(from: messageSearch?.draft.content ?? "")
    }
}
