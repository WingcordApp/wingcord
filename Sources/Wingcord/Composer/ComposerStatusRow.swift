import SwiftUI
import WingcordCore

/// The line above the composer: who is typing on the leading side, what
/// slowmode says on the trailing one.
///
/// **Two containers in one row, each reading only what it draws**, so somebody
/// starting to type does not re-read the slowmode and a wait running out does
/// not re-read who is typing. Like the typing pill alone, the row reserves no
/// height when neither half has anything to say — see `TypingIndicator`.
struct ComposerStatusRow: View {
    var channelID: ChannelID

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            TypingIndicatorContainer(channelID: channelID)
            SlowmodeIndicatorContainer(channelID: channelID)
        }
        // **The row holds the width, not the typing pill.** The pill's own
        // full-width frame goes with it when nobody is typing — a frame on an
        // empty group is nothing — and the row then hugged the slowmode notice
        // alone and was centred under the transcript.
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}
