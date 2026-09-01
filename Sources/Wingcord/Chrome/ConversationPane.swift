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
        }
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { chromeHeight = $0 }
    }

    private var transcript: some View {
        TimelineContainer(
            channelID: channelID,
            topInset: chromeHeight + callHeight,
            bottomInset: composerHeight
        )
            // **The one composed thing over the drawn transcript.** It is glass,
            // Core Graphics cannot draw glass, and there is exactly one of it at
            // a time — see `MessageActionBar`. Overlaid rather than inset, so it
            // floats over the rows the way a flyout does.
            .overlay { MessageActionBarOverlay(channelID: channelID) }
            // **The transcript runs to the window's foot, under the composer.**
            //
            // Left inset by the bar, the scroll view stops above it — so the
            // composer's glass had the opaque reading surface behind it and
            // nothing to refract, which is the flat black slab it looked like.
            // Extending underneath and paying for it with a content inset is
            // what puts moving content beneath the material.
            .ignoresSafeArea(.container, edges: [.top, .bottom])
            // **No `scrollEdgeEffectStyle` here, and it is not an oversight.**
            // Measured on this window in both styles, with and without
            // `.fullSizeContentView` and with the titlebar's material left
            // alone: it draws nothing. The API reaches SwiftUI `ScrollView`s and
            // titlebar accessories; `NSScrollView` has no property for it. The
            // transcript's own edge is `ScrollEdgeBlur`, installed inside the
            // scroll view — which is the only place a backdrop can see it.
            // `safeAreaBar`, not `safeAreaInset`: the composer registers as a
            // bar, which is what the scroll edge effect keys off.
            .safeAreaBar(edge: .bottom, spacing: 0) {
                // The indicator rides INSIDE the bar rather than over the
                // transcript, so the height it takes is measured with the
                // composer's and the newest message is never hidden behind it.
                VStack(spacing: 0) {
                    // Above the composer, not below it. The composer floats at
                    // the window's foot, so a line under it is a line jammed
                    // against the edge of the screen.
                    TypingIndicatorContainer(channelID: channelID)
                    ComposerContainer(channelID: channelID)
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
