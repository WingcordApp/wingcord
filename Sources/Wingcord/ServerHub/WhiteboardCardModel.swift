import Foundation
import WingcordCore

/// The whiteboard, resolved for drawing.
struct WhiteboardCardModel: Equatable {
    /// The hub's own channel, which the whiteboard runs in.
    var channelID: ChannelID?
    var access: Access
    /// Running here now: the card holds it live.
    var isRunning: Bool
    var isLaunching: Bool
    /// Editing: the card shows the board's place, never a live board.
    var isEditing: Bool
    /// The people on the board right now, when the reader isn't (faces, then
    /// how many). From Discord's own instance list.
    var drawing: [Face] = []
    var drawingCount = 0
    /// The reader has authorized the whiteboard app before: the board opens by
    /// itself, as Discord's widget does.
    var opensByItself = false

    struct Face: Equatable, Identifiable {
        var id: UserID
        var url: URL?
        var monogram: String
    }

    enum Access: Equatable {
        case allowed
        /// Use Activities is denied to the reader in the hub's channel.
        case denied
        /// Discord sent no channel for the hub, so there is nowhere to run it.
        case unavailable
    }
}
