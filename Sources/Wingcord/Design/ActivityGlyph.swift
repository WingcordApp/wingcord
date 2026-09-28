import WingcordCore

/// The symbol for each glyph an activity line leads with.
///
/// **Discord's icons, by meaning** (modules `835072` and `78871`): a gamepad for
/// a game, a note for music, a screen for anything watched or shared, a speaker
/// for a call. One table for every surface that draws the line — the member
/// list, the direct-message list, the now bar — so a game reads the same in all
/// of them.
///
/// `nonisolated` because the member list's painter runs off the main actor.
nonisolated extension ActivityStatusLine.Glyph {
    var symbolName: String {
        switch self {
        case .game: "gamecontroller.fill"
        case .music: "music.note"
        case .screen: "display"
        case .activity: "puzzlepiece.extension.fill"
        case .stage: "person.wave.2.fill"
        case .voice: "speaker.wave.2.fill"
        }
    }

    /// Whether Discord draws this glyph in the online green rather than in the
    /// line's own ink. Only a call is: it is the one lead that says somebody can
    /// be joined right now.
    var isLive: Bool { self == .voice }
}
