import SwiftUI
import WingcordCore

/// Reads the store and hands the timeline its rows.
struct TimelineContainer: View {
    var channelID: ChannelID

    @Environment(AppModel.self) private var model
    @State private var presentation = PresentationRevision.shared

    var body: some View {
        TimelineView(
            channelID: channelID,
            rows: model.timelineRows(for: channelID),
            presentationRevision: presentation.value,
            model: model
        )
    }
}
