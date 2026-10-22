import Foundation

// MARK: - Registered Games
//
// docs/CLIPS-PRESENCE.md, Phase 6 (D22.3). Discord's Registered Games: every
// game this machine has seen, with "Last played …" or "Now playing!", and per
// game a detection switch ("Toggle detection"), an overlay switch ("Toggle
// overlay", "Overlay: On / Off") and — Wingcord's own, since its clips run per
// game — a clips switch. Games added by hand sit in the same list and are the
// only ones that can be removed: a game the detector knows comes straight
// back the next time it runs, so removing it would be a button that lies.
//
// Kept on this Mac: Discord keeps it in the client too, because it describes
// what is installed here.

/// One game this machine has run.
public struct RegisteredGame: Hashable, Sendable, Codable, Identifiable {
    /// Discord's application id, or the synthetic one a game added by hand
    /// gets.
    public var id: UInt64
    public var name: String
    /// When it last stopped running — or started, while it runs.
    public var lastPlayed: Date
    /// Whether it was added by hand, which is what makes it removable.
    public var isAddedByHand: Bool
    /// "Toggle detection": off, the game is not detected at all — no
    /// activity, no overlay, no clips, no Game Mode.
    public var isDetected: Bool
    /// "Toggle overlay".
    public var showsOverlay: Bool
    /// Whether the clip buffer runs while it is in front.
    public var recordsClips: Bool

    public init(
        id: UInt64,
        name: String,
        lastPlayed: Date,
        isAddedByHand: Bool = false,
        isDetected: Bool = true,
        showsOverlay: Bool = true,
        recordsClips: Bool = true
    ) {
        self.id = id
        self.name = name
        self.lastPlayed = lastPlayed
        self.isAddedByHand = isAddedByHand
        self.isDetected = isDetected
        self.showsOverlay = showsOverlay
        self.recordsClips = recordsClips
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, lastPlayed, isAddedByHand, isDetected, showsOverlay, recordsClips
    }

    /// Lenient, so a switch added later reads as on.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UInt64.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        lastPlayed = try container.decodeIfPresent(Date.self, forKey: .lastPlayed) ?? .distantPast
        isAddedByHand = try container.decodeIfPresent(Bool.self, forKey: .isAddedByHand) ?? false
        isDetected = try container.decodeIfPresent(Bool.self, forKey: .isDetected) ?? true
        showsOverlay = try container.decodeIfPresent(Bool.self, forKey: .showsOverlay) ?? true
        recordsClips = try container.decodeIfPresent(Bool.self, forKey: .recordsClips) ?? true
    }
}

/// Every game seen, and the switches on each.
public struct RegisteredGames: Hashable, Sendable, Codable {
    public private(set) var games: [RegisteredGame]

    public init(games: [RegisteredGame] = []) {
        self.games = games
    }

    /// The most kept. A machine that has run four hundred applications as
    /// games over the years does not need a list four hundred long; the
    /// oldest that nobody switched anything on fall off the end.
    public static let limit = 200

    public func game(_ id: UInt64) -> RegisteredGame? {
        games.first { $0.id == id }
    }

    // MARK: What the switches say
    //
    // A game never seen has every switch on: the detector found it, so it is
    // detected, and nothing has been said about it yet.

    public func isDetected(_ id: UInt64) -> Bool { game(id)?.isDetected ?? true }
    public func showsOverlay(_ id: UInt64) -> Bool { game(id)?.showsOverlay ?? true }
    public func recordsClips(_ id: UInt64) -> Bool { game(id)?.recordsClips ?? true }

    /// The list as Registered Games draws it: most recently played first.
    public var byLastPlayed: [RegisteredGame] {
        games.sorted { lhs, rhs in
            if lhs.lastPlayed != rhs.lastPlayed { return lhs.lastPlayed > rhs.lastPlayed }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    // MARK: Seeing them

    /// A game is running: remembered, or its clock moved on.
    ///
    /// **The name follows the database** — a game renamed upstream is renamed
    /// here — except for one added by hand, whose name the reader chose.
    public mutating func noteRunning(id: UInt64, name: String, at date: Date) {
        if let index = games.firstIndex(where: { $0.id == id }) {
            games[index].lastPlayed = max(games[index].lastPlayed, date)
            if !games[index].isAddedByHand { games[index].name = name }
            return
        }
        games.append(RegisteredGame(id: id, name: name, lastPlayed: date))
        trim()
    }

    /// A game the reader added by hand. Adding one already there makes it
    /// theirs.
    public mutating func add(id: UInt64, name: String, at date: Date) {
        if let index = games.firstIndex(where: { $0.id == id }) {
            games[index].isAddedByHand = true
            games[index].name = name
            return
        }
        games.append(RegisteredGame(id: id, name: name, lastPlayed: date, isAddedByHand: true))
        trim()
    }

    /// Removes a game added by hand. A detected game is not removable — it
    /// comes back the next time it runs — so asking to is refused.
    @discardableResult
    public mutating func remove(_ id: UInt64) -> Bool {
        guard let index = games.firstIndex(where: { $0.id == id }), games[index].isAddedByHand else {
            return false
        }
        games.remove(at: index)
        return true
    }

    // MARK: The switches

    public mutating func setDetected(_ on: Bool, for id: UInt64, name: String) {
        update(id, name: name) { $0.isDetected = on }
    }

    public mutating func setShowsOverlay(_ on: Bool, for id: UInt64, name: String) {
        update(id, name: name) { $0.showsOverlay = on }
    }

    public mutating func setRecordsClips(_ on: Bool, for id: UInt64, name: String) {
        update(id, name: name) { $0.recordsClips = on }
    }

    private mutating func update(_ id: UInt64, name: String, _ change: (inout RegisteredGame) -> Void) {
        if let index = games.firstIndex(where: { $0.id == id }) {
            change(&games[index])
            return
        }
        // A switch on a game the list has not kept yet — the one running now,
        // before its first note — keeps it.
        var game = RegisteredGame(id: id, name: name, lastPlayed: Date())
        change(&game)
        games.append(game)
        trim()
    }

    /// Drops the oldest games nobody changed anything on, past the limit.
    private mutating func trim() {
        guard games.count > Self.limit else { return }
        let removable = games
            .filter { !$0.isAddedByHand && $0.isDetected && $0.showsOverlay && $0.recordsClips }
            .sorted { $0.lastPlayed < $1.lastPlayed }
            .prefix(games.count - Self.limit)
            .map(\.id)
        let doomed = Set(removable)
        games.removeAll { doomed.contains($0.id) }
    }
}
