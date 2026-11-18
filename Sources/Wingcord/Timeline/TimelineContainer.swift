import SwiftUI
import WingcordCore

/// Reads the store and hands the timeline its rows.
struct TimelineContainer: View {
    var channelID: ChannelID
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0
    /// How much of `bottomInset` the typing and slowmode row takes — it rides
    /// in the composer's bar — so the clearance can count it as air
    /// (`TimelineMetrics.clearance(above:)`).
    var statusHeight: CGFloat = 0
    /// Whether this is the transcript the toolbar's summaries follow — the pill
    /// names the stretch it shows, the steps move it — and the one that carries
    /// the new-messages pill.
    ///
    /// **The main conversation's alone.** The toolbar is about the channel the
    /// window is showing, not a thread panel, a voice channel's chat or the
    /// overlay's small window.
    var hostsSummaries = false

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var presentation = PresentationRevision.shared
    @State private var settings = AppSettings.shared
    /// This transcript's position as the chrome over it sees it. Written by the
    /// coordinator, read by the jump control and by nothing here.
    @State private var scroll = TranscriptScrollState()
    /// The wallpaper's frost — read here so the drawn canvas hears it change.
    @State private var frost = WallpaperFrost.shared

    var body: some View {
        let summaries = hostsSummaries ? model.summaries(in: channelID) : []
        // **Nothing for a channel with no summaries** — a pill that can only say
        // there is nothing is chrome spent on nothing. The list first, so a
        // transcript that hosts none never reads the switch and never
        // re-evaluates when it moves.
        let showsSummaries = !summaries.isEmpty && settings.showsSummaryBar
        // The main conversation's alone, as the summaries are: Discord shows
        // it over the channel, not over a thread panel or a small window.
        let banner = hostsSummaries ? model.newMessagesBanner(in: channelID) : nil
        // The summaries are on the toolbar row now, so nothing takes a band of the rows.
        let chromeBottom = topInset
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
            uploadProgress: model.uploadProgress(in: channelID),
            topInset: chromeBottom,
            // The rows stop short of the composer by a little air — less
            // where the typing or slowmode row already holds some; the chrome
            // laid over the transcript still measures from the bar.
            bottomInset: bottomInset + TimelineMetrics.clearance(above: statusHeight),
            // Read here for the reason the accents are: the transcript is a
            // drawn canvas, and a card that resolved without something SwiftUI
            // owns changing would never be told to draw it.
            cardRevision: model.cardRevision,
            head: model.channelIndex[channelID].map(model.channelHead(for:)) ?? .channel,
            postActions: model.postActions(for: channelID),
            playingPreview: model.spotifyPreviewURL,
            voiceRevision: model.voicePlayer.revision,
            // The held note's in the composer, which keeps its own clock.
            isVoiceLive: (model.voicePlayer.isPlaying || model.voicePlayer.isLoading)
                && model.voicePlayer.current != VoiceNotePlayer.heldNote,

            // Read narrowly: a jump for a different channel is not this
            // transcript's business, and passing it would restart the
            // coordinator's update for nothing.
            jump: model.pendingJump.flatMap { $0.channelID == channelID ? $0 : nil },
            reachesPresent: model.messages(in: channelID)?.hasMoreNewer != true,
            // Narrow for the jump's reason.
            present: model.presentRequest.flatMap { $0.channelID == channelID ? $0 : nil },
            // Narrow for the jump's reason.
            flight: model.sendFlight.flatMap { $0.channelID == channelID ? $0 : nil },
            scroll: scroll,
            topics: model.conversationTopics[channelID]?.topics ?? [],
            // Only while the bar is up: its place is the one thing tracked.
            summaries: showsSummaries ? summaries : [],
            // Narrow for the jump's reason.
            // The toolbar's topic steers the conversation's transcript only; a
            // column beside a page opens at the channel's newest messages.
            selectedSummary: hostsSummaries
                ? model.selectedSummary.flatMap { $0.channelID == channelID ? $0 : nil }
                : nil,
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
            pinnedReactionMessage: model.reactionPicker.flatMap { $0.channelID == channelID ? $0.messageID : nil },
            hidesMedia: model.channelIndex[channelID]?.messageRequest != nil,
            listenAlongCards: model.listenAlongCards(in: channelID),
            // Read here so a stage chat observes the hands: Invite to Speak
            // under a request is drawn, and a drawn canvas only hears what
            // SwiftUI re-evaluates.
            stageInvitations: model.openStageRequests(in: channelID),
            // And the stickers other Fake Nitro users' GIF uploads stand for,
            // which a server's stickers arriving can change.
            fakeGIFStickers: model.fakeGIFStickers(in: channelID),
            // And the event on now here, whose card a stage start wears.
            liveEvent: model.liveEvent(in: channelID).map {
                TimelineLayoutEngine.LiveEvent(guildID: $0.guildID, id: $0.id, name: $0.name)
            },
            frostRevision: frost.revision,
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
        //
        // **Only on the conversation's own transcript** (Alex, 2026-11-18):
        // in a column beside a page — a channel opened from the guide or
        // Browse Channels — its topic list and its message preview had no
        // room and covered the column's header and its rows.
        .overlay(alignment: .trailing) {
            if hostsSummaries {
                TopicMinimap(channelID: channelID, scroll: scroll)
                    .padding(.trailing, Spacing.tight)
                    .padding(.top, chromeBottom)
                    .padding(.bottom, bottomInset)
                    .ignoresSafeArea(.container, edges: .bottom)
            }
        }
        // **Under the toolbar, over the rows' top.** Measured from the
        // transcript's own top, as the inset is, whatever the pane does with
        // its safe area — the jump control's reason.
        .overlay(alignment: .top) {
            ZStack {
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
                    .frame(height: NewMessagesPill.bandHeight)
                    .transition(.materialize(from: .top, blurring: false))
                }
            }
            .padding(.top, topInset)
            .ignoresSafeArea(.container, edges: .top)
            .animation(motion.panel, value: banner == nil)
        }
        // The toolbar's summaries read where the main transcript is: see `AppModel.summaryScroll`.
        .onAppear { if hostsSummaries { model.summaryScroll = scroll } }
        .onDisappear { if model.summaryScroll === scroll { model.summaryScroll = nil } }
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
