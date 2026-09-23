import SwiftUI
import WingcordCore

/// Reads the store and hands the timeline its rows.
struct TimelineContainer: View {
    var channelID: ChannelID
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0

    @Environment(AppModel.self) private var model
    @State private var presentation = PresentationRevision.shared

    var body: some View {
        TimelineView(
            channelID: channelID,
            rows: model.timelineRows(for: channelID),
            presentationRevision: presentation.value,
            // Read here so the container is what observes it: a colour landing
            // has to re-evaluate *something* SwiftUI owns, or the drawn canvas
            // is never told. See `AppModel.activityAccents`.
            activityAccents: model.activityAccents,
            // Read here so the container observes `presences`: the status turns
            // on presence, and a drawn canvas is only told what SwiftUI
            // re-evaluates.
            activityInviteStatuses: model.activityInviteStatuses(in: channelID),
            topInset: topInset,
            bottomInset: bottomInset,
            // Read here for the reason the accents are: the transcript is a
            // drawn canvas, and a card that resolved without something SwiftUI
            // owns changing would never be told to draw it.
            spotifyRevision: model.spotifyRevision,
            playingPreview: model.spotifyPreviewURL,

            // Read narrowly: a jump for a different channel is not this
            // transcript's business, and passing it would restart the
            // coordinator's update for nothing.
            jump: model.pendingJump.flatMap { $0.channelID == channelID ? $0 : nil },
            // Read here for the reason the accents are, and it is the one input
            // whose *absence* was a visible defect: see
            // `AppModel.isWindowCovered`.
            isCovered: model.isWindowCovered,
            bookmarks: model.bookmarkedMessageIDs,
            // Read here for the reason the accents are: whether a super
            // reaction chip is a control is decided by the account, and a drawn
            // canvas is only told what SwiftUI re-evaluates.
            canSuperReact: model.hasNitro,
            model: model
        )
    }
}
