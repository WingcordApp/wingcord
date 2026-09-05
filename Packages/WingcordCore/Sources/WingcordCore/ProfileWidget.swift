import Foundation

/// One tile on somebody's profile board.
///
/// **Five kinds, and only two of them are the same shape.** Four are lists of
/// games the person annotated; the fifth is an application's own widget, whose
/// entire content is authored by the application and arrives from two other
/// routes. Modelling them as one struct with an optional `games` and an optional
/// `applicationID` — which is literally how the wire sends it — is how a board
/// ends up drawing an empty game list for a widget that never had one.
///
/// So the payload is an enum and the envelope is not. `id` and `updatedAt`
/// belong to the tile: the id is what a report names, and it is the only stable
/// handle a board has for a tile whose content is a list that can be reordered.
public struct ProfileWidget: Hashable, Sendable, Identifiable {
    public var id: String
    public var updatedAt: Date?
    public var content: Content

    public init(id: String, updatedAt: Date? = nil, content: Content) {
        self.id = id
        self.updatedAt = updatedAt
        self.content = content
    }

    /// What the tile actually holds.
    public enum Content: Hashable, Sendable {
        /// The person's one favourite game, drawn large with its comment and
        /// tags. Discord caps it at one; the array is kept because the wire
        /// sends an array and a client that assumed otherwise would drop a
        /// second entry silently rather than showing it.
        case favouriteGames([ProfileWidgetGame])
        /// "Games in Rotation" — up to five, each with its own tags.
        case currentGames([ProfileWidgetGame])
        /// "Games I Like" — up to twenty, drawn as covers only.
        case playedGames([ProfileWidgetGame])
        /// "Want to Play" — up to twenty, drawn as covers only.
        case wantToPlayGames([ProfileWidgetGame])
        /// An application's own widget: a linked game's stats, or something a
        /// developer authored. Nothing here says what it looks like — that is
        /// the application's `WidgetConfig`, fetched separately.
        case application(ApplicationID)
        /// A kind added after this was written. Drawn as nothing rather than as
        /// a broken tile — `INVARIANTS.md` §5.5.
        case unknown(String)
    }

    /// The wire's `type` string, which is what a write has to send back.
    public var typeName: String {
        switch content {
        case .favouriteGames: ProfileWidgetKind.favouriteGames.rawValue
        case .currentGames: ProfileWidgetKind.currentGames.rawValue
        case .playedGames: ProfileWidgetKind.playedGames.rawValue
        case .wantToPlayGames: ProfileWidgetKind.wantToPlayGames.rawValue
        case .application: ProfileWidgetKind.application.rawValue
        case .unknown(let name): name
        }
    }

    /// The games it lists, or empty for an application widget.
    public var games: [ProfileWidgetGame] {
        switch content {
        case .favouriteGames(let games), .currentGames(let games),
             .playedGames(let games), .wantToPlayGames(let games):
            games
        case .application, .unknown:
            []
        }
    }

    /// The application it belongs to, or nil for a game list.
    public var applicationID: ApplicationID? {
        if case .application(let id) = content { return id }
        return nil
    }

    /// Whether this tile is drawn with each game's comment and tags rather than
    /// as a grid of covers.
    ///
    /// The distinction is Discord's and it is not a layout preference: the
    /// annotations only *exist* on these two kinds, so a grid kind drawn in
    /// detail shows a column of games with nothing under any of them.
    public var isDetailed: Bool {
        switch content {
        case .favouriteGames, .currentGames: true
        default: false
        }
    }

    /// The heading over the tile.
    public var title: String {
        switch content {
        case .favouriteGames: "Favourite Game"
        case .currentGames: "Games in Rotation"
        case .playedGames: "Games I Like"
        case .wantToPlayGames: "Want to Play"
        case .application, .unknown: ""
        }
    }
}

/// The wire's `type` values, as a closed set.
///
/// Kept apart from `ProfileWidget.Content` because the two answer different
/// questions: this one is what a *write* names and what the caps are indexed by,
/// while the content is what a board draws. An editor needs the first without
/// having to construct the second.
public enum ProfileWidgetKind: String, Hashable, Sendable, CaseIterable {
    case favouriteGames = "favorite_games"
    case currentGames = "current_games"
    case playedGames = "played_games"
    case wantToPlayGames = "want_to_play_games"
    case application

    /// How many games Discord accepts in this kind. Nil for the application
    /// widget, which holds none.
    ///
    /// **The write route rejects an over-long list rather than truncating it**,
    /// so an editor that does not check this loses the whole save rather than
    /// the last entry.
    public var gameLimit: Int? {
        switch self {
        case .favouriteGames: 1
        case .currentGames: 5
        case .playedGames, .wantToPlayGames: 20
        case .application: nil
        }
    }

    public var title: String {
        switch self {
        case .favouriteGames: "Favourite Game"
        case .currentGames: "Games in Rotation"
        case .playedGames: "Games I Like"
        case .wantToPlayGames: "Want to Play"
        case .application: "Game"
        }
    }
}

/// One game on a tile, as the person annotated it.
public struct ProfileWidgetGame: Hashable, Sendable, Identifiable {
    /// The game's **application** id — the same id `/games` is queried by, and
    /// the same id an application widget carries.
    public var gameID: ApplicationID
    /// A line the person wrote about it. Only drawn on a detailed tile.
    public var comment: String?
    public var tags: [GameWidgetTag]

    public var id: ApplicationID { gameID }

    public init(gameID: ApplicationID, comment: String? = nil, tags: [GameWidgetTag] = []) {
        self.gameID = gameID
        self.comment = comment.flatMap { $0.isEmpty ? nil : $0 }
        self.tags = tags
    }
}

/// A badge under a game on a detailed tile.
///
/// **Three groups, and the grouping is a rule rather than a garnish.** Discord
/// permits exactly one skill tag at a time and any number of the others, so an
/// editor needs to know which group a tag is in before it can enforce that —
/// and a board needs it to order the chips, because a skill badge before a
/// feeling badge is the order every captured profile draws them in.
///
/// An unrecognised value keeps its raw string and is titled from it. Discord
/// adds tags without warning, and a client that dropped them would show a game
/// with fewer badges than the person put on it.
public enum GameWidgetTag: Hashable, Sendable {
    case skill(Skill)
    case feeling(Feeling)
    case social(Social)
    case unknown(String)

    public enum Skill: String, Hashable, Sendable, CaseIterable {
        case noob
        case learningTheRopes = "learning_the_ropes"
        case casual
        case gettingGood = "getting_good"
        case intermediate
        case expert
        case betterThanYou = "better_than_you"

        public var title: String {
            switch self {
            case .noob: "Noob"
            case .learningTheRopes: "Learning the Ropes"
            case .casual: "Casual"
            case .gettingGood: "Getting Good"
            case .intermediate: "Intermediate"
            case .expert: "Expert"
            case .betterThanYou: "Better Than You"
            }
        }
    }

    public enum Feeling: String, Hashable, Sendable, CaseIterable {
        case obsessed
        case loveIt = "love_it"
        case kindOfLoveIt = "kind_of_love_it"
        case likeIt = "like_it"
        case tooEasy = "too_easy"
        case frustrated
        case kindOfHateIt = "kind_of_hate_it"
        case rageQuitting = "rage_quitting"

        public var title: String {
            switch self {
            case .obsessed: "Obsessed"
            case .loveIt: "Love It"
            case .kindOfLoveIt: "Kind of Love It"
            case .likeIt: "Like It"
            case .tooEasy: "Too Easy"
            case .frustrated: "Frustrated"
            case .kindOfHateIt: "Kind of Hate It"
            case .rageQuitting: "Rage Quitting"
            }
        }

        /// Whether the feeling is a warm one. The chip leans on this for its
        /// glyph, so the two halves of the scale do not read alike.
        public var isPositive: Bool {
            switch self {
            case .obsessed, .loveIt, .kindOfLoveIt, .likeIt, .tooEasy: true
            case .frustrated, .kindOfHateIt, .rageQuitting: false
            }
        }
    }

    public enum Social: String, Hashable, Sendable, CaseIterable {
        case lookingForGroup = "looking_for_group"
        case openToPlay = "open_to_play"
        case lookingForTips = "looking_for_tips"
        case openToTeach = "open_to_teach"
        case lookingToDiscuss = "looking_to_discuss"

        public var title: String {
            switch self {
            case .lookingForGroup: "Looking for Group"
            case .openToPlay: "Open to Play"
            case .lookingForTips: "Looking for Tips"
            case .openToTeach: "Open to Teach"
            case .lookingToDiscuss: "Looking to Discuss"
            }
        }
    }

    public init(rawValue: String) {
        if let skill = Skill(rawValue: rawValue) {
            self = .skill(skill)
        } else if let feeling = Feeling(rawValue: rawValue) {
            self = .feeling(feeling)
        } else if let social = Social(rawValue: rawValue) {
            self = .social(social)
        } else {
            self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .skill(let value): value.rawValue
        case .feeling(let value): value.rawValue
        case .social(let value): value.rawValue
        case .unknown(let value): value
        }
    }

    public var title: String {
        switch self {
        case .skill(let value): value.title
        case .feeling(let value): value.title
        case .social(let value): value.title
        // Titled from the wire rather than shown raw: `open_to_duo` reads as a
        // key, "Open To Duo" reads as a badge, and one of them is what the
        // person chose.
        case .unknown(let value):
            value.split(separator: "_")
                .map(\.capitalized)
                .joined(separator: " ")
        }
    }

    /// The symbol beside the title.
    ///
    /// Skill is a trophy, feeling is a thumb, social is a pair — three glyphs
    /// for three groups rather than one per tag, so the badge reads as its
    /// *kind* before it is read as its words.
    public var symbolName: String {
        switch self {
        case .skill: "trophy"
        case .feeling(let value): value.isPositive ? "hand.thumbsup" : "hand.thumbsdown"
        case .social: "person.2"
        case .unknown: "tag"
        }
    }

    /// Skill first, then feeling, then social — the order every captured
    /// profile draws them in, and the order an editor should offer them in.
    public var sortRank: Int {
        switch self {
        case .skill: 0
        case .feeling: 1
        case .social: 2
        case .unknown: 3
        }
    }
}
