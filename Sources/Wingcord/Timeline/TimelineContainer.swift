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
            topInset: topInset,
            bottomInset: bottomInset,
            // Read narrowly: a jump for a different channel is not this
            // transcript's business, and passing it would restart the
            // coordinator's update for nothing.
            jump: model.pendingJump.flatMap { $0.channelID == channelID ? $0 : nil },
            model: model
        )
    }
}
