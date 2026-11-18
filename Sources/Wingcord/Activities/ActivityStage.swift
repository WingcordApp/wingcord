import SwiftUI
import WingcordCore

/// A running activity, over the conversation it was launched into.
///
/// **Inset, not overlaid** — the same arrangement a call takes, and for the
/// same reason: an activity that hides the last four messages is an activity
/// people close in order to read, which defeats the point of having it in the
/// conversation. The height is reported upward so the transcript can make room.
///
/// **Only in the channel it belongs to.** An instance is launched into one
/// channel and its id says which; opening a different conversation leaves it
/// running but takes it off screen, exactly as a call in another channel is
/// not drawn over this one.
struct ActivityStageContainer: View {
    var channelID: ChannelID
    /// The hub's whiteboard card: the activity fills the card, edge to edge,
    /// with no bar of its own (Alex, 2026-11-17) — leaving the page leaves
    /// the board, as Discord's does (`AppModel.leaveServerHub`).
    var fillsCard = false
    var onHeightChange: (CGFloat) -> Void

    @Environment(AppModel.self) private var model

    /// **Only where nothing else holds it** (decision 3): a conversation with a
    /// call puts the activity on the call's stage, never in a second band
    /// under it; the hub's card and a conversation without a call are this
    /// band's two places (`AppModel.activityHost`).
    private var activity: RunningActivity? {
        guard let running = model.runningActivity,
              running.instance.location.channelID == channelID,
              model.activityHost == .band || model.activityHost == .hub
        else { return nil }
        return running
    }

    var body: some View {
        if let activity, fillsCard {
            // **No measuring in the hub's card** (Alex, 2026-11-18: the
            // whiteboard "is too big its a weird bug"): a `GeometryReader`
            // takes every point it is offered, so the card grew to the column's
            // height with the board fixed at the top of it. The card is never
            // dragged, so it has no room to measure.
            ActivityStage(activity: activity, fillsCard: true, room: ServerHubMetrics.whiteboardHeight)
                .onDisappear { onHeightChange(0) }
        } else if let activity {
            // **The conversation's height is the band's ceiling**, so the
            // reader drags it into the room there is and no further — the
            // call band's arrangement (`VoiceCallOverlay`).
            GeometryReader { proxy in
                ActivityStage(activity: activity, fillsCard: fillsCard, room: proxy.size.height)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        onHeightChange(height)
                    }
                    .onDisappear { onHeightChange(0) }
            }
        }
    }
}

private struct ActivityStage: View {
    var activity: RunningActivity
    var fillsCard: Bool
    /// The height the conversation offers the band.
    var room: CGFloat

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion

    /// The game's height at rest. **Resizable since 2026-11-18** (Alex:
    /// "making them resizeable"): it used to be fixed on the grounds that a
    /// handle could only reflow somebody else's app mid-game — but the reader
    /// is the one who knows whether the game wants the room or the chat does.
    @State private var height = ActivityStage.restingHeight
    /// Live drag offset, applied on top of `height` and 1:1 with the pointer.
    @State private var drag: CGFloat = 0
    /// The capsule's Fill the Conversation, as the call band's.
    @State private var isFullHeight = false
    @State private var isPointerInBand = false
    @State private var isGrabberHovering = false

    static let minimumHeight: CGFloat = 220
    static let restingHeight: CGFloat = 420
    /// The strip at the band's foot that holds the handle.
    static let grabberStrip: CGFloat = 12

    /// What the band holds under the game: the gap, the capsule, the handle.
    private static var chrome: CGFloat {
        Spacing.base + CallCapsuleMetrics.height + grabberStrip
    }

    /// The game's tallest by drag: three quarters of the conversation, so a
    /// few messages and the composer always stay in sight.
    private var ceiling: CGFloat {
        max(Self.minimumHeight, room * 0.75 - Self.chrome)
    }

    private var gameHeight: CGFloat {
        if isFullHeight { return max(Self.minimumHeight, room - Self.chrome) }
        // Rubber-banded outside the bounds and 1:1 inside them, as the call
        // band's: a hard stop reads as frozen.
        return Motion.clampWithResistance(height + drag, to: Self.minimumHeight...ceiling, limit: ceiling)
    }

    var body: some View {
        if fillsCard {
            // The card's own shape clips it; nothing here draws an edge.
            frame
                .frame(height: ServerHubMetrics.whiteboardHeight)
                .transition(.opacity)
                .animation(motion.panel, value: activity.instance)
        } else {
            VStack(spacing: 0) {
                // **The game is a card of its own**, edge to edge with nothing
                // drawn on it (Alex, 2026-11-18: the dark bar under it went).
                frame
                    .frame(height: gameHeight)
                    .clipShape(.rect(cornerRadius: Radius.glass, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Radius.glass, style: .continuous)
                            .strokeBorder(Palette.hoverFill, lineWidth: 1)
                            .allowsHitTesting(false)
                    }
                ActivityStageCapsule(activity: activity, isFullHeight: $isFullHeight)
                    .padding(.top, Spacing.base)
                grabber
            }
            .padding(.horizontal, Spacing.snug)
            // **The call band's ground, up under the toolbar**: the band is the
            // same kind of thing, and without it the messages scrolled under
            // the band showed through around the game.
            .background { CallBandGround().ignoresSafeArea(.container, edges: .top) }
            .onHover { hovering in
                guard isPointerInBand != hovering else { return }
                isPointerInBand = hovering
            }
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(motion.panel, value: activity.instance)
            .animation(motion.reposition, value: isFullHeight)
        }
    }

    /// The web view, with the app's own artwork under it until it paints.
    ///
    /// **A `WKWebView` that has not painted is a white rectangle**, and a white
    /// rectangle in the middle of a near-black window reads as a fault rather
    /// than as loading. The icon holds the space until the frame says READY.
    private var frame: some View {
        ZStack {
            Palette.surfaceRaised
            if !activity.isReady {
                VStack(spacing: Spacing.snug) {
                    RemoteImage(url: activity.iconURL, side: Metrics.activityHeaderIcon) {
                        Color.clear
                    }
                    .frame(
                        width: Metrics.activityHeaderIcon,
                        height: Metrics.activityHeaderIcon
                    )
                    .clipShape(
                        .rect(
                            cornerRadius: Metrics.activityHeaderIcon * 0.28,
                            style: .continuous
                        )
                    )
                    ProgressView().controlSize(.small)
                }
            }
            if let runtime = model.activityRuntime, runtime.instance == activity.instance {
                ActivityWebView(runtime: runtime)
                    .opacity(activity.isReady ? 1 : 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The handle at the band's foot: the call band's, shown while the
    /// pointer is over the band.
    private var grabber: some View {
        Capsule()
            .fill(isGrabberHovering ? Palette.edgeStrong : Palette.edge)
            .frame(width: 44, height: 4)
            .opacity(!isFullHeight && (isPointerInBand || isGrabberHovering || drag != 0) ? 1 : 0)
            .frame(maxWidth: .infinity)
            .frame(height: Self.grabberStrip)
            .contentShape(.rect)
            .onHover { hovering in
                guard isGrabberHovering != hovering else { return }
                isGrabberHovering = hovering
                // Pushed and popped, never set: a cursor set on hover-in and
                // never restored leaks into the whole window.
                if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(resize)
            .animation(motion.hover, value: isGrabberHovering)
            .animation(motion.standard, value: isPointerInBand)
            .accessibilityLabel(Text("Resize \(activity.name)"))
            .accessibilityValue(Text("\(Int(gameHeight)) points tall"))
            .accessibilityAdjustableAction { direction in
                let step: CGFloat = direction == .increment ? 32 : -32
                height = min(ceiling, max(Self.minimumHeight, height + step))
            }
    }

    /// Measured in the window, never in the handle's own space: the handle
    /// moves with the band's foot, and a local translation would be measured
    /// from a frame that is itself moving (the call band's flicker, 2026-11-18).
    private var resize: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                guard !isFullHeight else { return }
                drag = value.translation.height
            }
            .onEnded { value in
                guard !isFullHeight else { return }
                let target = min(ceiling, max(Self.minimumHeight, height + value.translation.height))
                let settled = height + drag
                height = settled
                drag = 0
                // **Velocity handoff**: the settle starts at the pointer's
                // release speed, so there is no seam between drag and spring.
                withAnimation(motion.handoff(velocity: value.velocity.height, over: target - settled)) {
                    height = target
                }
            }
    }
}
