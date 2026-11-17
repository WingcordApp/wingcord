import Foundation

/// The small markers under an activity's title — "3w ago", "New Player",
/// "Top Artist – 14 tracks this week" — **Discord's per-kind lists, in its
/// order and its words for each place** (`506326`, 2026-11-17;
/// docs/ACTIVITY-CARDS.md decision 5).
///
/// One engine for the member list's card, its popout, the card a reply
/// carries into a DM, and the profile's Recent Activity: Discord draws the
/// same functions in all four and changes only the wording and the green.
public enum ActivityMarkers {

    /// Where a marker is drawn — Discord's `N5` locations this client draws.
    public enum Place: Hashable, Sendable {
        case card, popout, embed, profile
    }

    /// What the reader's client knows beyond the entry: the live presence it
    /// matches, the voice channel, the stream.
    public struct Context: Hashable, Sendable {
        /// The live presence's party line, "In a Match (2 of 4)" — Discord's
        /// `gF(state, party)`.
        public var party: String?
        /// The voice channel the author is in, for a live entry the reader may
        /// see — the card's marker (the popout draws a voice bar instead).
        public var voiceChannelName: String?
        /// Whether the author is streaming it now.
        public var isStreaming: Bool
        /// When the entry happened — its id's time — for the streak's "the
        /// last two days" rule.
        public var entryDate: Date?
        public var now: Date

        public init(party: String? = nil, voiceChannelName: String? = nil, isStreaming: Bool = false,
                    entryDate: Date? = nil, now: Date) {
            self.party = party
            self.voiceChannelName = voiceChannelName
            self.isStreaming = isStreaming
            self.entryDate = entryDate
            self.now = now
        }
    }

    /// The marker list for one entry in one place.
    public static func markers(for activity: RecentActivity, at place: Place, context: Context) -> [ActivityMarker] {
        switch activity.subject {
        case .listening:
            return [topArtist(activity, place)].compactMap { $0 }
        case .topGame:
            return [mostPlayed(activity, place)].compactMap { $0 }
        case .watched:
            return [clock(activity, place, context, symbol: "tv.fill", greenAt: [.profile]), episode(activity)]
                .compactMap { $0 }
        case .listeningSession:
            return [clock(activity, place, context, symbol: "music.note", greenAt: [.card, .profile])].compactMap { $0 }
        case .game:
            return [
                clock(activity, place, context, symbol: gameSymbol(context), greenAt: [.card, .profile]),
                party(context), voice(context, place), newRelease(activity, context), newPlayer(activity, place),
                streak(activity, place, context), trending(activity), returning(activity, place, context),
                marathon(activity, place),
            ].compactMap { $0 }
        case .activity:
            return [
                clock(activity, place, context, symbol: context.isStreaming ? "display" : "square.grid.2x2.fill",
                      greenAt: [.card, .profile]),
                party(context), voice(context, place), newRelease(activity, context), trending(activity),
                marathon(activity, place),
            ].compactMap { $0 }
        }
    }

    // MARK: Each marker (Discord's function names in `506326`)

    private static func gameSymbol(_ context: Context) -> String {
        context.isStreaming ? "display" : "gamecontroller.fill"
    }

    /// `$` / `tc` / `R_`: the clock — the running time while live, "3w ago"
    /// after; green while live, where Discord greens it.
    private static func clock(
        _ activity: RecentActivity, _ place: Place, _ context: Context, symbol: String, greenAt: Set<Place>
    ) -> ActivityMarker? {
        let green = activity.isOngoing(at: context.now) && greenAt.contains(place)
        return ActivityMarker(symbol: symbol, text: .clock, tintsSymbol: green, tintsText: green)
    }

    /// `tt`: the party, from the live presence.
    private static func party(_ context: Context) -> ActivityMarker? {
        guard let party = context.party, !party.isEmpty else { return nil }
        return ActivityMarker(symbol: "person.2.fill", text: .words(party))
    }

    /// `Q`: the voice channel — on the card only; the popout has its bar.
    private static func voice(_ context: Context, _ place: Place) -> ActivityMarker? {
        guard place == .card, let name = context.voiceChannelName, !name.isEmpty else { return nil }
        return ActivityMarker(symbol: "speaker.wave.2.fill", text: .words(name))
    }

    /// `ts`: a game or activity released in the last week.
    private static func newRelease(_ activity: RecentActivity, _ context: Context) -> ActivityMarker? {
        guard ActivityCardRules.isNewRelease(activity.subject.applicationID, now: context.now) else { return nil }
        return ActivityMarker(symbol: "sparkles", text: .words("New Release"))
    }

    /// `te`: a first time — the glyph green on the card.
    private static func newPlayer(_ activity: RecentActivity, _ place: Place) -> ActivityMarker? {
        guard activity.traits.contains(.newPlayer) else { return nil }
        return ActivityMarker(symbol: "leaf.fill", text: .words("New Player"), tintsSymbol: place == .card)
    }

    /// `tr`: three days or more, on an entry from the last two.
    private static func streak(_ activity: RecentActivity, _ place: Place, _ context: Context) -> ActivityMarker? {
        guard let days = activity.traits.lazy.compactMap({ trait -> Int? in
            if case .streak(let days) = trait { return days } else { return nil }
        }).first,
            ActivityCardRules.showsStreak(days: days, entryDate: context.entryDate, now: context.now)
        else { return nil }
        return ActivityMarker(
            symbol: "bolt.fill",
            text: .words("\(days)x Streak"),
            tooltip: place == .card ? "Played \(days) days in a row" : nil,
            accessibilityText: "\(days)-day streak"
        )
    }

    /// `ta`.
    private static func trending(_ activity: RecentActivity) -> ActivityMarker? {
        guard activity.traits.contains(.trending) else { return nil }
        return ActivityMarker(symbol: "flame.fill", text: .words("Trending"))
    }

    /// `tl`: "Returning" on the card with the whole sentence as its tooltip,
    /// the sentence everywhere else.
    private static func returning(_ activity: RecentActivity, _ place: Place, _ context: Context) -> ActivityMarker? {
        guard let since = activity.traits.lazy.compactMap({ trait -> Date? in
            if case .returning(let date) = trait { return date } else { return nil }
        }).first else { return nil }
        let sentence = RecentActivity.Trait.returningLabel(since: since, now: context.now)
        return place == .card
            ? ActivityMarker(symbol: "arrow.clockwise", text: .words("Returning"), tooltip: sentence)
            : ActivityMarker(symbol: "arrow.clockwise", text: .words(sentence))
    }

    /// `tn`: a marathon of at least an hour; the tooltip says how long, on a
    /// card that isn't live.
    private static func marathon(_ activity: RecentActivity, _ place: Place) -> ActivityMarker? {
        guard activity.traits.contains(.marathon), let duration = activity.duration else { return nil }
        let hours = Int((duration / 3600).rounded())
        guard hours > 0 else { return nil }
        return ActivityMarker(
            symbol: "timer",
            text: .words("\(hours)h Marathon"),
            tooltip: place == .card && !activity.isLive ? "Played for \(hours)h" : nil,
            accessibilityText: "\(hours) hour marathon"
        )
    }

    /// `ti`: the week's track count — Discord's longer words off the card.
    private static func topArtist(_ activity: RecentActivity, _ place: Place) -> ActivityMarker? {
        guard let count = activity.weeklyCount else { return nil }
        let text = place == .card || place == .profile
            ? "\(count.formatted()) tracks this week"
            : "Top Artist \u{2013} \(count.formatted()) tracks this week"
        return ActivityMarker(symbol: "trophy.fill", text: .words(text))
    }

    /// `to`: the week's hours on the game somebody played most.
    private static func mostPlayed(_ activity: RecentActivity, _ place: Place) -> ActivityMarker? {
        guard let duration = activity.duration else { return nil }
        let hours = Int((duration / 3600).rounded())
        let text = place == .card ? "Most played: \(hours)h" : "Most played \u{2014} \(hours)h this week"
        return ActivityMarker(symbol: "trophy.fill", text: .words(text))
    }

    /// `tu`: "S1E3", spoken in full.
    private static func episode(_ activity: RecentActivity) -> ActivityMarker? {
        guard let marker = activity.details.episodeMarker else { return nil }
        return ActivityMarker(symbol: "text.bubble.fill", text: .words(marker), accessibilityText: activity.details.episodeText)
    }
}

/// One marker: a glyph and its words, perhaps a tooltip, perhaps green.
public struct ActivityMarker: Hashable, Sendable {
    public enum Text: Hashable, Sendable {
        /// The running clock while live, "3w ago" after — resolved when drawn.
        case clock
        case words(String)
    }

    /// An SF Symbol standing for Discord's icon.
    public var symbol: String
    public var text: Text
    public var tooltip: String?
    /// Discord's positive green on the glyph — New Player on a card, a live clock.
    public var tintsSymbol: Bool
    /// …and on the words: a live clock.
    public var tintsText: Bool
    /// What VoiceOver says where the words are an abbreviation.
    public var accessibilityText: String?

    public init(
        symbol: String, text: Text, tooltip: String? = nil, tintsSymbol: Bool = false, tintsText: Bool = false,
        accessibilityText: String? = nil
    ) {
        self.symbol = symbol
        self.text = text
        self.tooltip = tooltip
        self.tintsSymbol = tintsSymbol
        self.tintsText = tintsText
        self.accessibilityText = accessibilityText
    }
}

extension ActivityCardRules {

    /// Whether Discord draws an entry at all (`420018`): a top artist or top
    /// game counts a week; a listening session needs the author's presence to
    /// still be playing it — otherwise Discord's row is an empty box, so it is
    /// left out here.
    public static func isDrawable(_ activity: RecentActivity, isStillListening: Bool) -> Bool {
        switch activity.subject {
        case .listening: activity.isWeekly && activity.weeklyCount != nil
        case .topGame: activity.isWeekly && activity.duration != nil
        case .listeningSession: isStillListening
        case .game, .activity, .watched: true
        }
    }

    /// Discord's party words (`583846`'s `gF`): the state and "(2 of 4)", or
    /// just the count, or just the state.
    public static func partyText(state: String?, size: [Int]?) -> String? {
        var count: String?
        if let size, size.count == 2, size[0] > 0, size[1] > 0 {
            count = "\(size[0]) of \(size[1])"
        } else if let first = size?.first, first > 0 {
            count = "\(first)"
        }
        switch (state, count) {
        case (let state?, let count?): return "\(state) (\(count))"
        case (let state?, nil): return state
        case (nil, let count?): return count
        case (nil, nil): return nil
        }
    }
}
