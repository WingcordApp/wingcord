import Foundation

/// Popular Music, resolved for drawing: three lists behind one picker.
struct PopularMusicCardModel: Equatable {
    var songs: [Row]
    var artists: [Row]
    var listeners: [Row]
    /// The top song's cover, blurred behind the card.
    var backdropURL: URL?
    /// "128 songs played by 31 members".
    var summary: String?

    enum Tab: Hashable, CaseIterable {
        case songs
        case artists
        case listeners

        var title: String {
            switch self {
            case .songs: "Top Songs"
            case .artists: "Top Artists"
            case .listeners: "Top Listeners"
            }
        }
    }

    func rows(_ tab: Tab) -> [Row] {
        switch tab {
        case .songs: songs
        case .artists: artists
        case .listeners: listeners
        }
    }

    struct Row: Equatable, Identifiable {
        var id: String
        var rank: Int
        var title: String
        var detail: String?
        var imageURL: URL?
        /// A person, drawn round; a song or an artist is square.
        var isPerson: Bool
        var monogram: String
        var plays: String
    }
}
