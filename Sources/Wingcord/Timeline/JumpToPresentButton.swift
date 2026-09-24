import SwiftUI
import WingcordCore

/// What one transcript's scroll position means to the chrome over it.
///
/// **Owned by the container and written by the coordinator**, because only the
/// coordinator knows where the viewport is and only SwiftUI can draw glass. It
/// is written on a change of answer, never per tick, and it is read by the one
/// control it concerns — so the transcript's own container, and the drawn
/// canvas under it, do not re-evaluate when it flips.
@Observable
final class TranscriptScrollState {
    /// Whether the control that returns to the present is showing. See
    /// `TimelineViewportPolicy.showsJumpToPresent`.
    var showsJumpToPresent = false
    /// The topic the reader is in, as an index into the channel's topics — the
    /// one the minimap centres on. Nil when there are none. See `TopicPlace`.
    var topicIndex: Int?
    /// Where the reader is among the channel's summaries — what the bar names
    /// and where its arrows go. Nil until first reported. See `SummaryPlace`.
    var summaryPlace: SummaryPlace?
    /// The pointer is on chrome over the transcript — the minimap, the jump
    /// control — so the canvas under it must not light the row there.
    ///
    /// **A tracking area is not occlusion-tested** (`INVARIANTS.md` §1): the
    /// canvas hears every move under these controls, and without this the row
    /// beneath the minimap raised its hover pill right on top of it.
    var isPointerOverChrome = false

    /// Records the pointer entering or leaving a piece of that chrome.
    func pointer(overChrome over: Bool) {
        if isPointerOverChrome != over { isPointerOverChrome = over }
    }
}

/// The way back to the present: a round glass control at the transcript's
/// bottom-trailing corner, above the composer.
///
/// **Reads the scroll state and nothing else until it shows.** The unread mark
/// is resolved only inside the branch that draws it, so a hidden control
/// registers no dependency on the channel table — which moves on every message
/// in the account.
struct JumpToPresentButton: View {
    var channelID: ChannelID
    var scroll: TranscriptScrollState

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion

    var body: some View {
        let shows = scroll.showsJumpToPresent
        ZStack {
            if shows {
                JumpToPresentControl(hasUnreadBelow: hasUnreadBelow) {
                    model.jumpToPresent(in: channelID)
                }
                .equatable()
                .onHover(perform: scroll.pointer(overChrome:))
                // A control that goes while the pointer is on it — the glide
                // it started hides it — hears no exit, and the latch would
                // leave the canvas covered.
                .onDisappear { scroll.pointer(overChrome: false) }
                .transition(.materialize(from: .bottom, blurring: false))
            }
        }
        .animation(motion.panel, value: shows)
    }

    /// Whether messages have arrived that the reader has not reached — the
    /// channel's newest is past what was last acknowledged, and the
    /// transcript only acknowledges at the present.
    private var hasUnreadBelow: Bool {
        guard let newest = model.channelIndex[channelID]?.lastMessageID else { return false }
        guard let read = model.readStates[channelID]?.lastAcknowledgedID else { return true }
        return newest.rawValue > read.rawValue
    }
}

/// The control itself: an arrow in the hover pill's glass, and a mark when
/// there is something new below.
private struct JumpToPresentControl: View, Equatable {
    var hasUnreadBelow: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(Typeface.controlGlyph)
                .foregroundStyle(InkColor.solid)
                .frame(width: Metrics.composerControlHeight, height: Metrics.composerControlHeight)
                // **Inside the label, so inside the glass's own content** — the
                // one place §4 guarantees draws over the material. Accent,
                // because it says the same thing the unread divider's colour
                // does: there is more to read.
                .overlay(alignment: .topTrailing) {
                    if hasUnreadBelow {
                        Circle()
                            .fill(Palette.accent)
                            .frame(width: 9, height: 9)
                            .offset(x: -3, y: 3)
                    }
                }
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        // The hover pill's material: it floats over the transcript, so what
        // passes under it is content, and `.clear` is what lets it lens.
        .glassEffect(.clear.interactive(), in: .circle)
        .specularEdge(in: Circle())
        .help("Jump to Present")
        .accessibilityLabel(Text("Jump to Present"))
        .accessibilityValue(Text(hasUnreadBelow ? "New messages below" : ""))
    }

    static func == (lhs: JumpToPresentControl, rhs: JumpToPresentControl) -> Bool {
        lhs.hasUnreadBelow == rhs.hasUnreadBelow
    }
}
