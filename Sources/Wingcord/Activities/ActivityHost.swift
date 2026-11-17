/// Where the running activity's frame is drawn.
enum ActivityHost: Hashable, Sendable {
    /// Inside the call it runs in, on the call's stage.
    case call
    /// Above a conversation with no call, where the call band would be.
    case band
    /// In the Server Hub's whiteboard card.
    case hub
    /// The small window over everything else in this one.
    case pictureInPicture
    /// Its own window.
    case popout
}
