import SwiftUI
import WingcordCore

/// Reads the store and hands the timeline its rows.
struct TimelineContainer: View {
    var channelID: ChannelID
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0

    @Environment(AppModel.self) private var model
    @State private var presentation = PresentationRevision.shared
    /// This transcript's position as the chrome over it sees it. Written by the
    /// coordinator, read by the jump control and by nothing here.
    @State private var scroll = TranscriptScrollState()

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
            reachesPresent: model.messages(in: channelID)?.hasMoreNewer != true,
            // Narrow for the jump's reason.
            present: model.presentRequest.flatMap { $0.channelID == channelID ? $0 : nil },
            scroll: scroll,
            topics: model.conversationTopics[channelID]?.topics ?? [],
            // Read here for the reason the accents are, and it is the one input
            // whose *absence* was a visible defect: see
            // `AppModel.isWindowCovered`.
            // …and the chrome this container lays over the transcript: the
            // pointer on the minimap or the jump control, or a topic's panel
            // up over the rows.
            isCovered: model.isWindowCovered || scroll.isPointerOverChrome
                || model.openTopic.map { $0.channelID == channelID && $0.showsPanel } == true,
            bookmarks: model.bookmarkedMessageIDs,
            // Read here for the reason the accents are: whether a super
            // reaction chip is a control is decided by the account, and a drawn
            // canvas is only told what SwiftUI re-evaluates.
            canSuperReact: model.hasNitro,
            model: model
        )
        // **Over the transcript's own corner, lifted clear of the composer** —
        // every surface that draws a transcript gets the way back to its
        // present. The inset is the bar's measured height, the typing and
        // slowmode line included, so the control never sits on either.
        //
        // **Measured from the scroll view's own foot, exactly as the content
        // inset is**, whatever each pane does with its safe area: the
        // conversation pane ignores it and the thread panel composes a bar, and
        // a control that respected the safe area would sit in a different place
        // in each.
        .overlay(alignment: .bottomTrailing) {
            JumpToPresentButton(channelID: channelID, scroll: scroll)
                .padding(.trailing, Spacing.margin)
                .padding(.bottom, bottomInset + Spacing.base)
                .ignoresSafeArea(.container, edges: .bottom)
        }
        // **The topics, at the trailing edge and the middle of what can be
        // read** — Discord's place for them — between the chrome above and the
        // composer below.
        .overlay(alignment: .trailing) {
            TopicMinimap(channelID: channelID, scroll: scroll)
                .padding(.trailing, Spacing.tight)
                .padding(.top, topInset)
                .padding(.bottom, bottomInset)
                .ignoresSafeArea(.container, edges: .bottom)
        }
        // Over everything else on the transcript, the minimap included: it is
        // the one modal layer here.
        .overlay {
            TopicPanel(channelID: channelID, topInset: topInset, bottomInset: bottomInset)
        }
    }
}
