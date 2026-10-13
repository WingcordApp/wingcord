import WingcordCore

/// The symbol for each glyph an activity line leads with.
///
/// **Discord's icons, by meaning** (modules `835072` and `78871`): a gamepad for
/// a game, a note for music, a screen for anything watched or shared, a speaker
/// for a call. One table for every surface that draws the line — the member
/// list, the direct-message list, the now bar — so a game reads the same in all
/// of them.
///
/// **Every one is green.** Discord's activity icon (module `864436`) colours
/// the glyph with the online status colour whatever it stands for — a game, a
/// song, a share or a call — and the line's words stay muted beside it.
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

}
