import Foundation
import WingcordCore

/// Everything the Server Hub page draws, as plain values built once per change
/// (`AppModel.serverHubPresentation`). The views hold no store and work out
/// nothing — §2, as every other page in this app.
struct ServerHubPresentation: Equatable {
    var guildID: GuildID
    var header: Header
    /// The main column, then the side column.
    var columns: [[Widget]]
    var isEditing: Bool
    var canEdit: Bool
    var isPublished: Bool
    var phase: Phase
    var saveState: ServerHubDraft.SaveState
    var hasChanges: Bool
    var isPublishing: Bool

    enum Phase: Equatable {
        case loading
        case failed
        /// Discord has no hub for this server and the reader can't make one.
        case missing
        case ready
    }

    var widgetCount: Int { columns.reduce(0) { $0 + $1.count } }
    var showsDraftNotice: Bool { canEdit && !isPublished && phase == .ready }

    struct Header: Equatable {
        var name: String
        var iconURL: URL?
        var monogram: String
        /// The hub's banner, or the server's.
        var bannerURL: URL?
        /// A banner picked in this edit and not yet saved.
        var bannerPreview: Data?
        /// What fills the banner when there's no picture: the server's brand colour.
        var tint: UInt32?
        /// Whether there's a banner of the hub's own to take away.
        var hasCustomBanner: Bool
        var onlineCount: Int?
        var memberCount: Int?
        var boostCount: Int
    }

    struct Widget: Equatable, Identifiable {
        var id: String
        var kind: GuildSpaceWidgetKind
        var title: String
        var symbolName: String?
        /// The leaderboard's "1d left", beside the title.
        var accessory: String?
        var accessoryHelp: String?
        var content: Content
        /// Behind a Boost power-up the server hasn't unlocked.
        var isLocked: Bool
        var boostPrice: Int?
        /// What Edit opens, or nil where there's nothing to set.
        var settings: ServerHubSheet?
        /// Whether the card offers its full-size sheet.
        var expansion: ServerHubSheet?

        enum Content: Equatable {
            case loading
            case failed
            /// A widget that will only have something to show once saved.
            case awaitingSave(title: String, detail: String)
            case notEnoughData(title: String, detail: String)
            case leaderboard(LeaderboardCardModel)
            case popularGames(PopularGamesCardModel)
            case popularMusic(PopularMusicCardModel)
            case imageText(ImageTextCardModel)
            case whiteboard(WhiteboardCardModel)
        }
    }
}
