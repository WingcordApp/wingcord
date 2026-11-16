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

    enum Access: Equatable {
        case allowed
        /// Use Activities is denied to the reader in the hub's channel.
        case denied
        /// Discord sent no channel for the hub, so there is nowhere to run it.
        case unavailable
    }
}
