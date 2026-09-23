import SwiftUI
import WingcordCore

// MARK: - What somebody LIVE is actually streaming
//
// Hovering a row in the voice widget that carries the LIVE pill opens this
// beside it: a thumbnail of the share, the game's mark and name, the three state
// lines rich presence already carries, and the one control that matters.
//
// **Every field on it is decoded already.** `details`, `state` and `startedAt`
// are the three lines Discord draws — "In Match", "Squads (4 of 4)", "05:47
// elapsed" — and the thumbnail is `STREAM_PREVIEW`, a route this client has been
// asking for on the main window's voice flyout since that surface landed. There
// is nothing new on the wire here at all.
//
// **It takes clicks, and the flyout one window over deliberately does not.** In
// the main window the two things this card could offer are already on the
// channel row's own hover accessories a line above it; on the overlay there is
// no row accessory and no second way in, so Watch Stream has to live here.

/// Which row the pointer is resting on, and where that row is.
struct OverlayStreamHover: Hashable, Sendable {
    var userID: UserID
    /// The row's box in the overlay's own coordinate space.
    var anchor: CGRect
}

struct OverlayStreamHoverCard: View {
    @Bindable var controller: OverlayController
    var surface: CGSize

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion

    /// Wide enough for a 16:9 frame that still reads as a screen, narrow enough
    /// not to cover the roster it is pointing at. The same number the main
    /// window's flyout uses.
    private static let width: CGFloat = 288
    /// The gap between the row and the card.
    private static let gap: CGFloat = Spacing.base
    /// How often the thumbnail is re-asked for while the card is open. Discord's
    /// own preview rotates about this often; faster is a request for a frame
    /// that has not changed.
    private static let refresh = Duration.seconds(5)

    var body: some View {
        if let hover = controller.streamHover, let participant = participant(hover.userID) {
            card(for: participant, hover: hover)
                .frame(width: Self.width)
                .fixedSize(horizontal: false, vertical: true)
                // **Positioned, not laid out.** The card is a layer over the
                // whole surface; giving it a place in a stack would make every
                // widget's slot depend on whether a pointer happened to be
                // resting on a row.
                .offset(x: origin(for: hover).x, y: origin(for: hover).y)
                .frame(width: surface.width, height: surface.height, alignment: .topLeading)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .leading)))
                .animation(motion.hover, value: hover.userID)
        }
    }

    private func participant(_ userID: UserID) -> VoiceParticipant? {
        model.voicePresentation?.participants.first { $0.id == userID }
    }

    /// The activity behind the share, when the person published one.
    ///
    /// Nil is a real state: somebody sharing a window Discord cannot name has a
    /// stream and no rich presence, and the card then draws the frame alone
    /// rather than three blank lines.
    private func activity(_ userID: UserID) -> Activity? {
        model.presences[userID]?.primaryActivity
    }

    // MARK: Where it goes

    /// Beside the row, and flipped to the other side rather than cut off.
    ///
    /// **The flip is not a nicety.** The voice widget's default place is hard
    /// against the left edge, but it is draggable — and a card that always
    /// opened to the right would run off the screen the moment somebody moved
    /// the roster there. The vertical clamp is the same argument: a card hanging
    /// off the bottom is a card whose Watch button cannot be pressed.
    private func origin(for hover: OverlayStreamHover) -> CGPoint {
        let height = Self.estimatedHeight
        let toRight = hover.anchor.maxX + Self.gap
        let toLeft = hover.anchor.minX - Self.gap - Self.width
        let x = toRight + Self.width <= surface.width ? toRight : max(0, toLeft)
        let y = min(max(0, hover.anchor.midY - height / 2), max(0, surface.height - height))
        return CGPoint(x: x, y: y)
    }

    /// What the clamp above measures against.
    ///
    /// **A constant rather than a measurement**, and the trade is deliberate:
    /// measuring the card writes a value into state, costs a second layout pass,
    /// and — §2 — outlives the card it measured, so the next row's card is
    /// placed from the last one's height. Being a few points out on the clamp is
    /// invisible; being placed from a stale number is the sidebar pill bug.
    private static let estimatedHeight: CGFloat = 268

    // MARK: The card

    private func card(for participant: VoiceParticipant, hover: OverlayStreamHover) -> some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            preview(for: participant)
            if let activity = activity(participant.id) {
                OverlayStreamLines(activity: activity, iconURL: model.applicationIconURL(
                    activity.applicationID, side: Metrics.activityRowIcon
                ))
            } else {
                Text("\(participant.displayName) is sharing a screen")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(2)
            }
            watchButton(for: participant)
        }
        .padding(Spacing.snug)
        // **Opaque, and §1 is what decides it.** The main window's voice flyout
        // is clear glass because what is behind it there is a transcript, and
        // lensing it is the design. This card can land anywhere on the overlay
        // — including on top of the chat window, which is itself an opaque
        // reading surface — and the first capture of it showed "Wordle" and
        // "How to Quote" reading straight through three lines of somebody's
        // rich presence. A card carrying prose is a reading surface.
        //
        // It still reads as floating: the rim is the light and the shadow is
        // the weight, which is the same pair the sidebar and the chat window
        // use over a game.
        .background(Palette.surface, in: .rect(cornerRadius: Radius.glass, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.glass, style: .continuous)
                .strokeBorder(hoverCardEdge, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.4), radius: 14, y: 4)
        // **The card keeps its own hover.** A reader travelling from the row to
        // the Watch button crosses the gap between them, and a card that closed
        // on the way is a control nobody can reach.
        .onHover { hovering in
            if hovering {
                controller.hoverStream(hover.userID, anchor: hover.anchor)
            } else {
                controller.endStreamHover(hover.userID)
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// The frame itself.
    ///
    /// **A region with a fixed ratio, not a picture with a size.** The address
    /// arrives a moment after the card does and a stream that has just ended
    /// never sends one at all, so the box is reserved first and filled if it can
    /// be — otherwise the card would grow under the pointer the instant the
    /// answer landed. §1.
    private func preview(for participant: VoiceParticipant) -> some View {
        let key = model.streamKey(for: participant.id)
        return RemoteImage(
            url: key.flatMap { model.streamPreviews[$0] },
            side: Self.width,
            bucket: .artwork
        ) {
            ZStack {
                Rectangle().fill(Palette.surfaceRaised)
                Image(systemName: "rectangle.inset.filled.on.rectangle")
                    .font(.system(size: 20))
                    .foregroundStyle(Ink.quaternary)
            }
        }
        .aspectRatio(contentMode: .fill)
        .frame(
            width: Self.width - Spacing.snug * 2,
            height: (Self.width - Spacing.snug * 2) * 9 / 16
        )
        .clipShape(.rect(cornerRadius: Radius.chip, style: .continuous))
        .overlay(alignment: .topTrailing) {
            LiveChip().padding(Spacing.base)
        }
        // A loop rather than a timer, so it dies with the card: the task is
        // cancelled the moment the pointer leaves the row.
        .task(id: key) {
            guard let key else { return }
            while !Task.isCancelled {
                model.requestStreamPreview(key: key)
                try? await Task.sleep(for: Self.refresh)
            }
        }
    }

    private func watchButton(for participant: VoiceParticipant) -> some View {
        Button {
            model.toggleWatchingStream(participant.id)
        } label: {
            Label(
                participant.isWatched ? "Stop Watching" : "Watch Stream",
                systemImage: participant.isWatched
                    ? "stop.fill" : "rectangle.inset.filled.on.rectangle"
            )
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Ink.primary)
            .frame(maxWidth: .infinity)
            .frame(height: Metrics.control)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .emphasisChrome(participant.isWatched ? Palette.destructive : Palette.accent)
        .accessibilityHint("Opens the share in the Streams widget")
    }
}

// MARK: - The three lines

/// The game's mark, its name, and what rich presence says is happening.
///
/// **Three lines and an elapsed clock, which is what the reference draws and
/// what the fields actually are**: `name`, then `details`, then `state`, then the
/// gap since `startedAt`. A client that drew them in any other order would be
/// inventing a hierarchy the publisher did not choose.
private struct OverlayStreamLines: View {
    var activity: Activity
    var iconURL: URL?

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.base) {
            RemoteImage(url: iconURL, side: Metrics.activityRowIcon) {
                ZStack {
                    Rectangle().fill(Palette.surfaceRaised)
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Ink.quaternary)
                }
            }
            .frame(width: Metrics.activityRowIcon, height: Metrics.activityRowIcon)
            .clipShape(.rect(cornerRadius: Radius.row, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(activity.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                if let details = activity.details {
                    Text(details)
                        .font(.system(size: 11))
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(1)
                }
                if let state = activity.state {
                    Text(state)
                        .font(.system(size: 11))
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(1)
                }
                if let startedAt = activity.startedAt {
                    // **The system's own running clock, not a string this view
                    // recomputes.** `Text(_:style:.timer)` is updated by
                    // SwiftUI's own timeline; a formatted interval here would
                    // need a subscription of this app's to tick at all — which
                    // is the exact shape of the bug the card canvas had.
                    Text(startedAt, style: .timer)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Ink.tertiary)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// The card's hairline: light in a dark room, shade in a light one.
private let hoverCardEdge = Color.relative(dark: 0.10, light: 0.10)
