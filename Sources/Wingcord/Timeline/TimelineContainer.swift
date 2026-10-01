import SwiftUI
import WingcordCore

/// Reads the store and hands the timeline its rows.
struct TimelineContainer: View {
    var channelID: ChannelID
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0
    /// Whether this transcript carries the channel's summaries bar.
    ///
    /// **The main conversation's alone.** The toolbar's Hide / Show Summaries
    /// is about the channel the window is showing, and a thread panel, a voice
    /// channel's chat or the overlay's small window would each be a second bar
    /// answering to a toggle that is not above it.
    var hostsSummaries = false

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var presentation = PresentationRevision.shared
    @State private var settings = AppSettings.shared
    /// This transcript's position as the chrome over it sees it. Written by the
    /// coordinator, read by the jump control and by nothing here.
    @State private var scroll = TranscriptScrollState()

    var body: some View {
        let summaries = hostsSummaries ? model.summaries(in: channelID) : []
        // **No bar for a channel with no summaries** — a pill that can only say
        // there is nothing is chrome spent on nothing. The list first, so a
        // transcript that hosts no bar never reads the switch and never
        // re-evaluates when it moves.
        let showsSummaryBar = !summaries.isEmpty && settings.showsSummaryBar
        // The main conversation's alone, as the summaries bar is: Discord shows
        // it over the channel, not over a thread panel or a small window.
        let banner = hostsSummaries ? model.newMessagesBanner(in: channelID) : nil
        // Everything below the bar starts where it ends: the rows, which is
        // what extends AppKit's scroll edge under the pills, and the minimap.
        let chromeBottom = topInset + (showsSummaryBar ? SummaryBar.reservedHeight : 0)
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
            topInset: chromeBottom,
            // The rows stop short of the composer by Discord's own air; the
            // chrome laid over the transcript still measures from the bar.
            bottomInset: bottomInset + TimelineMetrics.composerClearance,
            // Read here for the reason the accents are: the transcript is a
            // drawn canvas, and a card that resolved without something SwiftUI
            // owns changing would never be told to draw it.
            cardRevision: model.cardRevision,
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
            // Only while the bar is up: its place is the one thing tracked.
            summaries: showsSummaryBar ? summaries : [],
            // Narrow for the jump's reason.
            selectedSummary: model.selectedSummary.flatMap { $0.channelID == channelID ? $0 : nil },
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
            // The channel's answer, read here for the same reason: the add
            // control at the end of a reaction row is drawn, and a drawn
            // canvas only hears what SwiftUI re-evaluates.
            canAddReactions: model.permissionGate.canAddReaction(in: channelID),
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
                .padding(.top, chromeBottom)
                .padding(.bottom, bottomInset)
                .ignoresSafeArea(.container, edges: .bottom)
        }
        // **Under the toolbar, inside AppKit's scroll edge** — the pills sit in
        // the band the rows' top inset has just grown by, so what passes
        // beneath them is softened the way it is under the toolbar itself.
        // Measured from the transcript's own top, as the inset is, whatever the
        // pane does with its safe area — the jump control's reason.
        .overlay(alignment: .top) {
            ZStack {
                if showsSummaryBar {
                    SummaryBar(channelID: channelID, summaries: summaries, scroll: scroll)
                        .transition(.materialize(from: .top, blurring: false))
                }
                // **In the middle of the same band**, which the summaries bar
                // leaves free: its pill leads and its arrows trail.
                if let banner {
                    NewMessagesPill(
                        banner: banner,
                        jump: {
                            guard let first = banner.firstUnread else { return }
                            model.sessionController.jumpToMessage(first, in: channelID, highlights: false)
                        },
                        markRead: { model.markRead(channelID) }
                    )
                    .onHover(perform: scroll.pointer(overChrome:))
                    .onDisappear { scroll.pointer(overChrome: false) }
                    .frame(maxWidth: 420)
                    .frame(height: SummaryBar.reservedHeight)
                    .transition(.materialize(from: .top, blurring: false))
                }
            }
            .padding(.top, topInset)
            .ignoresSafeArea(.container, edges: .top)
            .animation(motion.panel, value: showsSummaryBar)
            .animation(motion.panel, value: banner == nil)
        }
        // Over everything else on the transcript, the minimap included: it is
        // the one modal layer here.
        .overlay {
            TopicPanel(channelID: channelID, topInset: chromeBottom, bottomInset: bottomInset)
        }
        // **Asked for once the session can answer**: keyed on readiness as well
        // as the channel, so a channel restored before READY is asked when READY
        // lands, and one on screen across a reconnect is asked again —
        // `markSummariesStale` is what makes the second ask go out.
        .task(id: SummaryFetchKey(
            channelID: channelID,
            isReady: hostsSummaries && model.connectionState == .ready
        )) {
            guard hostsSummaries, model.connectionState == .ready else { return }
            model.loadSummariesIfNeeded(in: channelID)
        }
    }
}

/// What the summaries fetch is keyed on. See the `.task` above.
private struct SummaryFetchKey: Equatable {
    var channelID: ChannelID
    var isReady: Bool
}
