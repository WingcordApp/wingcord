import SwiftUI
import WingcordCore

/// A text conversation: the transcript, and the composer floating over its foot.
struct ConversationPane: View {
    var channelID: ChannelID

    @Environment(AppModel.self) private var model

    var body: some View {
        TimelineContainer(channelID: channelID)
            // `safeAreaBar`, not `safeAreaInset`: the composer both reserves its
            // height AND registers as a bar, which is what makes messages blur
            // into it as they pass underneath instead of sliding under it sharp.
            .safeAreaBar(edge: .bottom, spacing: 0) {
                ComposerContainer(channelID: channelID)
            }
    }
}
