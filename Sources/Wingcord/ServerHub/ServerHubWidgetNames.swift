import WingcordCore

/// What a widget is called and wears before Discord's catalog says otherwise.
enum ServerHubWidgetNames {
    static func defaultTitle(_ kind: GuildSpaceWidgetKind) -> String {
        switch kind {
        case .leaderboard: "Gaming Leaderboard"
        case .whiteboard: "Whiteboard"
        case .popularGames: "Popular Games"
        case .popularMusic: "Popular Music"
        case .imageText: "Image + Text"
        default: "Widget"
        }
    }

    static func symbol(_ kind: GuildSpaceWidgetKind) -> String? {
        switch kind {
        case .leaderboard: "trophy"
        case .whiteboard: "pencil.and.scribble"
        case .popularGames: "gamecontroller"
        case .popularMusic: "music.note"
        default: nil
        }
    }
}
