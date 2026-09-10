import Foundation
import WingcordCore

// MARK: - Who and what a composer can name
//
// The store side of the `@` and `#` completions. The scan is pure and lives in
// `MentionAutocomplete`; this answers the question it asks.

extension AppModel {

    /// What to offer for a completion in progress.
    ///
    /// Nil rather than empty when there is no trigger, because "not
    /// completing" and "completing and nothing matches" are different states
    /// and the list draws them differently.
    func mentionCandidates(
        for trigger: MentionAutocomplete.Trigger,
        in channelID: ChannelID
    ) -> [MentionCandidate] {
        switch trigger.kind {
        case .member: memberCandidates(matching: trigger.query, in: channelID)
        case .channel: channelCandidates(matching: trigger.query, in: channelID)
        }
    }

    // MARK: People

    private func memberCandidates(
        matching query: String,
        in channelID: ChannelID
    ) -> [MentionCandidate] {
        let channel = channelIndex[channelID]
        let guildID = channel?.guildID
        var results: [MentionCandidate] = []
        results.reserveCapacity(MentionAutocomplete.limit)

        // **`@everyone` and `@here` first, and only where they are allowed.**
        // Offering one the server refuses is an inert control — §5.5 — and the
        // permission is real: `MENTION_EVERYONE` is what decides whether the
        // ping lands or the message goes out quietly ignoring it.
        if guildID != nil, permissionGate.permissions(in: channelID).contains(.mentionEveryone) {
            for special in ["everyone", "here"] where special.hasPrefix(query) {
                results.append(MentionCandidate(
                    id: "special-\(special)",
                    art: .symbol("at"),
                    title: "@\(special)",
                    subtitle: special == "everyone"
                        ? "Notify everybody in this server"
                        : "Notify everybody who is online",
                    // **The literal word, not a snowflake.** Discord has no id
                    // for these — the message carries the text and the server
                    // reads it — which is exactly why the token rides on the
                    // candidate rather than being rebuilt from an id.
                    token: "@\(special)"
                ))
            }
        }

        // **The people this channel is actually about.** A guild channel draws
        // from its roster; a direct message draws from its recipients, which
        // is a handful and never needs a fetch.
        let userIDs: [UserID] = if let guildID {
            Array((members[guildID] ?? [:]).keys)
        } else {
            channel?.recipientIDs ?? []
        }

        var matches: [(MentionCandidate, String)] = []
        for userID in userIDs {
            guard let user = users[userID] else { continue }
            let member = guildID.flatMap { members[$0]?[userID] }
            let name = member?.resolvedName(user: user) ?? user.preferredName
            let handle = user.handle
            // Prefix on either the displayed name or the handle: people
            // reach for whichever they remember, and Discord matches both.
            guard query.isEmpty
                || name.lowercased().hasPrefix(query)
                || handle.lowercased().hasPrefix(query)
            else { continue }
            matches.append((
                MentionCandidate(
                    id: "user-\(userID.rawValue)",
                    art: .avatar(avatarURL(for: user, side: Metrics.avatarRow), monogram: user.monogram),
                    title: name,
                    subtitle: handle.isEmpty ? nil : handle,
                    // `<@id>`, which is what the parser reads back — see
                    // `InlineScanner`. A bare `@name` is text.
                    token: "<@\(userID.rawValue)>",
                    nameColor: member.flatMap { member in
                        guildID.flatMap { roles[$0] }.flatMap {
                            RoleResolver.nameColorValue(of: member.roleIDs, in: $0)
                        }
                    }
                ),
                name.lowercased()
            ))
        }

        // Alphabetical, which is the only order that does not move under the
        // reader: a roster sorted by presence reshuffles while they are
        // choosing, and one sorted by id is arbitrary.
        results.append(
            contentsOf: matches
                .sorted { $0.1 < $1.1 }
                .prefix(MentionAutocomplete.limit - results.count)
                .map(\.0)
        )
        return results
    }

    // MARK: Channels

    private func channelCandidates(
        matching query: String,
        in channelID: ChannelID
    ) -> [MentionCandidate] {
        // **A direct message can still name a channel** — the link resolves
        // for anybody who can see it — but there is no list to draw from, so
        // the completion is offered only where the reader is in a server.
        guard let guildID = channelIndex[channelID]?.guildID else { return [] }

        var results: [(MentionCandidate, Int)] = []
        for (position, id) in channelIndex.channelIDs(inGuild: guildID).enumerated() {
            guard let channel = channelIndex[id], channel.kind != .category else { continue }
            // **The permission gate, once, here.** A channel the reader cannot
            // see is a channel they cannot link: the mention would render as a
            // dead `#unknown` for them and expose a name to everybody else.
            guard permissionGate.canView(id) else { continue }
            guard query.isEmpty || channel.name.lowercased().hasPrefix(query) else { continue }
            results.append((
                MentionCandidate(
                    id: "channel-\(id.rawValue)",
                    art: .symbol(channel.kind.symbolName),
                    title: channel.name,
                    // The category above it, which is how a reader tells two
                    // `#general`s apart.
                    subtitle: channel.parentID.flatMap { channelIndex[$0]?.name },
                    token: "<#\(id.rawValue)>"
                ),
                position
            ))
        }
        // The server's own order, which is the one the sidebar shows and
        // therefore the one the reader is holding in their head.
        return results
            .sorted { $0.1 < $1.1 }
            .prefix(MentionAutocomplete.limit)
            .map(\.0)
    }
}
