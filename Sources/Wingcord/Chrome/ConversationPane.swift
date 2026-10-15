import SwiftUI
import WingcordCore

/// A text conversation: the transcript, and the composer floating over its foot.
struct ConversationPane: View {
    var channelID: ChannelID

    /// The composer's measured height, handed to the transcript as a content
    /// inset. Measured rather than assumed: the bar grows with a reply banner
    /// and with a message long enough to wrap, and a hard-coded clearance is
    /// wrong in both directions the moment either happens.
    @State private var composerHeight: CGFloat = 0

    /// The toolbar's own strip, measured rather than assumed.
    ///
    /// **Read on a view that RESPECTS the safe area**, which is the whole reason
    /// this is on the outer `ZStack` and not on the transcript. §2's rule is
    /// counter-intuitive and was paid for once already: a reader that ignores an
    /// inset has been handed the region the inset describes and reports *zero*.
    @State private var chromeHeight: CGFloat = 0

    /// The call panel's outside height, when there is one.
    ///
    /// **The transcript is inset by it rather than covered by it.** A call that
    /// hides the last four messages is a call people close in order to read,
    /// which defeats the point of having it in the conversation. Measured for
    /// the same reason the composer's height is: the panel is resizable, so any
    /// constant here is wrong the moment somebody drags it.
    @State private var callHeight: CGFloat = 0

    /// The activity stage's outside height, when one is running here. Measured
    /// for the same reason the call panel's is, and added to the same inset —
    /// see `ActivityStageContainer`.
    @State private var activityHeight: CGFloat = 0

    /// Whether a drag carrying files is over this pane.
    @State private var isDropTargeted = false

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion

    var body: some View {
        ZStack(alignment: .top) {
            transcript
            VoiceCallOverlayContainer(channelID: channelID) { height in
                guard abs(callHeight - height) > 0.5 else { return }
                // A measured value: written with animations off, or the
                // transcript lurches on every frame of a resize drag. §3.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { callHeight = height }
            }
            ActivityStageContainer(channelID: channelID) { height in
                guard abs(activityHeight - height) > 0.5 else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { activityHeight = height }
            }
            .padding(.top, callHeight)
        }
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { chromeHeight = $0 }
        // **The whole conversation is the target, not the composer.** Somebody
        // dragging a photograph aims at the messages, which is where it is
        // going; asking them to hit a 38-point circle is asking them to aim at
        // the mechanism instead of at the outcome.
        //
        // The modifier is written unconditionally and the *predicate* carries
        // the permission — §2's rule about guarding the modifier rather than the
        // closure. A channel that refuses files answers false, so nothing lights
        // up and nothing is accepted.
        .dropDestination(for: URL.self) { urls, _ in
            guard model.canAttachFiles(in: channelID) else { return false }
            model.stageAttachments(urls, in: channelID)
            return true
        } isTargeted: { targeted in
            let allowed = targeted && model.canAttachFiles(in: channelID)
            guard allowed != isDropTargeted else { return }
            isDropTargeted = allowed
        }
        .overlay {
            if isDropTargeted { DropHalo() }
        }
        .animation(motion.standard, value: isDropTargeted)
    }

    private var transcript: some View {
        TimelineContainer(
            channelID: channelID,
            topInset: chromeHeight + callHeight + activityHeight,
            bottomInset: composerHeight,
            hostsSummaries: true
        )
            // **Out of the column's animation.** When the sidebar moves, the
            // header and the composer glide with it, but the transcript takes
            // its final width at once and dissolves into it — a drawn canvas
            // asked for every intermediate width re-lays out every row on each
            // frame, which is the lag the old split view had (REDESIGN.md R4).
            .transaction { $0.animation = nil }
            // **Rows fade out as they pass under the header**, rather than
            // scrolling sharp behind its glass. There is no toolbar to give
            // AppKit's own scroll edge something to key off any more, so this
            // is Noodle's arrangement: the pixels themselves are masked.
            .mask { TranscriptTopFade(clearHeight: chromeHeight) }
            // **The one composed thing over the drawn transcript.** It is glass,
            // Core Graphics cannot draw glass, and there is exactly one of it at
            // a time — see `MessageActionBar`. Overlaid rather than inset, so it
            // floats over the rows the way a flyout does.
            .overlay { MessageActionBarOverlay(channelID: channelID) }
            // Who reacted, over the chip the pointer rests on — composed over
            // the canvas for the pill's reason. See `ReactionTooltipOverlay`.
            .overlay { ReactionTooltipOverlay(channelID: channelID) }
            .overlay { GuildMarkTooltipOverlay() }
            .overlay { AutoModActionTooltipOverlay(channelID: channelID) }
            // **The transcript runs to the window's foot, under the composer.**
            //
            // Left inset by the bar, the scroll view stops above it — so the
            // composer's glass had the opaque reading surface behind it and
            // nothing to refract, which is the flat black slab it looked like.
            // Extending underneath and paying for it with a content inset is
            // what puts moving content beneath the material.
            .ignoresSafeArea(.container, edges: [.top, .bottom])
            // **The soft edge under the toolbar is AppKit's own.** A scroll view
            // that runs beneath the titlebar with a top content inset gets a
            // scroll pocket across that inset, and nothing here draws or gates
            // it. Two things in this window used to stop it and both are gone:
            // a title REMOVED rather than left empty (see `MainWindow`), and a
            // titlebar forced transparent. `scrollEdgeEffectStyle` is absent on
            // purpose — measured, `.soft` and `.hard` render byte-identically on
            // an `NSScrollView`, so here it would be a modifier that does
            // nothing. AppKit puts no pocket over the bottom inset, which keeps
            // the rows under the composer sharp for its glass to refract.
            // `safeAreaBar`, not `safeAreaInset`: the composer registers as a
            // bar, which is what the scroll edge effect keys off.
            .safeAreaBar(edge: .bottom, spacing: 0) {
                // The indicator rides INSIDE the bar rather than over the
                // transcript, so the height it takes is measured with the
                // composer's and the newest message is never hidden behind it.
                VStack(spacing: 0) {
                    // **A previewed server gets the way back, not a composer.**
                    // The reader cannot post, so a bar that says so and nothing
                    // else would spend the window's only fixed slot on a refusal
                    // — where the one thing they do need is the page that sent
                    // them here. The typing indicator goes with it: nobody is
                    // waiting on somebody who cannot type.
                    if model.isPreviewingSelectedGuild,
                       let preview = model.guildPreviewPresentation
                    {
                        PreviewReturnBar(preview: preview, back: { model.leavePreview() })
                            .padding(.horizontal, Spacing.snug)
                            .padding(.bottom, Spacing.snug)
                    } else if model.channelIndex[channelID]?.messageRequest != nil {
                        // **A request is answered before it is written in** —
                        // reached from a profile's Message, it is the same
                        // conversation the requests page opens, with the same
                        // bar where the composer will be.
                        MessageRequestBar(channelID: channelID)
                    } else if model.isSystemDirectMessage(channelID) {
                        // Discord's own messages take no reply: its blocker,
                        // its words, and its article on them.
                        ComposerBlocker(
                            message: "This chat is reserved for official Discord notifications.",
                            subtitle: "Discord will never ask you for your password or account token.",
                            image: SystemDirectMessageArt.image,
                            buttonTitle: "Learn More"
                        ) {
                            if let url = URL(string: "https://support.discord.com/hc/en-us/articles/360036118732") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    } else if let blocked = model.blockedRecipient(in: channelID) {
                        // Discord's own blocker: nothing can be sent to somebody
                        // the reader blocked, and the remedy is the one button.
                        ComposerBlocker(
                            message: "You cannot send messages to a user you have blocked.",
                            buttonTitle: "Unblock",
                            isBusy: model.relationshipsInFlight.contains(blocked)
                        ) {
                            model.setBlocked(false, userID: blocked)
                        }
                    } else {
                        // A locked thread's banner, as Discord puts it over
                        // the composer — see `ThreadBanner`.
                        ThreadBannerContainer(channelID: channelID)
                        // Above the composer, not below it. The composer floats
                        // at the window's foot, so a line under it is a line
                        // jammed against the edge of the screen.
                        ComposerStatusRow(channelID: channelID)
                        ComposerContainer(channelID: channelID)
                    }
                }
                .background {
                        GeometryReader { proxy in
                            Color.clear
                                .onChange(of: proxy.size.height, initial: true) { _, height in
                                    guard abs(composerHeight - height) > 0.5 else { return }
                                    // A measured value: written with animations
                                    // off, or the transcript lurches whenever
                                    // the composer grows a line.
                                    var transaction = Transaction()
                                    transaction.disablesAnimations = true
                                    withTransaction(transaction) { composerHeight = height }
                                }
                        }
                    }
            }
    }
}


/// What a drag over the transcript looks like.
///
/// **A ring and a wash, drawn inside the pane's own bounds** — not a sheet over
/// it. The reader has to keep seeing where they are aiming, and a panel that
/// covers the conversation to say "drop here" covers the thing that makes the
/// drop mean something.
///
/// It is inert: `allowsHitTesting(false)`, because a view that appears under a
/// drag and takes hits is a view that can cancel the drag it is advertising.
private struct DropHalo: View {
    var body: some View {
        ZStack {
            Palette.accent.opacity(0.10)
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Palette.accent.opacity(0.55), lineWidth: 2)
                .padding(Spacing.base)
            VStack(spacing: Spacing.base) {
                Image(systemName: "arrow.down.document")
                    .font(.system(size: 34, weight: .light))
                Text("Drop to attach")
                    .font(.system(.headline))
            }
            .foregroundStyle(Ink.primary)
            .padding(Spacing.group)
            .glassEffect(.regular, in: .rect(cornerRadius: Radius.glass))
        }
        .allowsHitTesting(false)
        .transition(.materialize(from: .bottom))
    }
}

/// The mask that fades the transcript under the header.
///
/// Clear across the header's own band at the very top, opaque a little below
/// it, so rows dissolve into the shade behind the header's glass instead of
/// being cut by its edge.
struct TranscriptTopFade: View {
    /// How far down the header reaches.
    var clearHeight: CGFloat

    /// How far past the header the fade runs before the rows are whole.
    private static let reach: CGFloat = 22

    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .white.opacity(0.10), location: 0.5),
                    .init(color: .white, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: max(1, clearHeight + Self.reach))
            Color.white
        }
        .allowsHitTesting(false)
    }
}
