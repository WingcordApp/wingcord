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
        Group {
            if let activity {
                ActivityStage(activity: activity, fillsCard: fillsCard)
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

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion

    /// How tall the stage runs. Fixed rather than resizable: an activity is a
    /// web page that lays itself out to whatever box it is given, and a drag
    /// handle here would be a control whose only effect is to reflow somebody
    /// else's app mid-game.
    private static let height: CGFloat = 420

    var body: some View {
        if fillsCard {
            // The card's own shape clips it; nothing here draws an edge.
            frame
                .frame(height: ServerHubMetrics.whiteboardHeight)
                .transition(.opacity)
                .animation(motion.panel, value: activity.instance)
        } else {
            VStack(spacing: 0) {
                frame
                bar
            }
            .frame(height: Self.height)
            .background(Palette.surface)
            .clipShape(.rect(cornerRadius: Radius.glass, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.glass, style: .continuous)
                    .strokeBorder(Palette.hoverFill, lineWidth: 1)
            }
            .padding(.horizontal, Spacing.snug)
            .padding(.bottom, Spacing.base)
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(motion.panel, value: activity.instance)
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

    /// The one bar, and the one control on it that matters.
    ///
    /// Under the frame rather than over it: an activity draws to its own edges
    /// and a bar floating on top of it would cover whatever the app put there.
    private var bar: some View {
        HStack(spacing: Spacing.base) {
            RemoteImage(url: activity.iconURL, side: 20) { Color.clear }
                .frame(width: 20, height: 20)
                .clipShape(.rect(cornerRadius: 6, style: .continuous))

            Text(activity.name)
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(Ink.primary)
                .lineLimit(1)

            Spacer(minLength: 0)

            Button {
                Task { await model.sessionController.leaveActivity() }
            } label: {
                Label("Leave", systemImage: "rectangle.portrait.and.arrow.right")
                    .labelStyle(.titleAndIcon)
                    .font(.system(.caption, weight: .semibold))
                    .padding(.horizontal, Spacing.snug)
                    .frame(height: Metrics.compactControl)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .emphasisChrome(Palette.destructive)
            .accessibilityLabel("Leave \(activity.name)")
        }
        .padding(.horizontal, Spacing.snug)
        .padding(.vertical, Spacing.base)
    }
}
