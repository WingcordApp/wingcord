import SwiftUI
import WingcordCore

/// What somebody in a voice channel is doing, beside the row they are in.
///
/// **An answer about the thing under the pointer, so it never becomes the thing
/// under the pointer** — the same rule every hover flyout in this app follows.
/// It takes no clicks: the two actions it could offer, joining the room and
/// opening the chat, are already on the channel row's own hover accessories one
/// line above it, and a card you have to travel into to press is a card that
/// closes on the way.
///
/// It is the one flyout in the app that **fetches**. A share's thumbnail is a
/// REST answer that nothing pushes, so it is asked for when the card opens and
/// re-asked while it stays open — see `AppModel.requestStreamPreview` for why
/// that is a hover-shaped cost rather than a polling one.
struct VoiceMemberFlyout: View {
    var member: VoiceMemberChip
    var channelID: ChannelID
    var guildID: GuildID?

    @Environment(AppModel.self) private var model

    /// Wide enough for a 16:9 frame that still reads as a screen, narrow enough
    /// that it does not cover the column it is pointing at.
    private static let width: CGFloat = 288
    /// The frame's own box, reserved before the address for it arrives.
    private static let previewSize = CGSize(
        width: width - Spacing.snug * 2,
        height: (width - Spacing.snug * 2) * 9 / 16
    )
    /// How often the thumbnail is re-asked for while the card is open. Discord's
    /// own preview rotates about this often; faster is a request for a frame
    /// that has not changed.
    private static let refresh = Duration.seconds(5)

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            if member.isStreaming { share }
            ForEach(Array(activities.enumerated()), id: \.offset) { index, activity in
                if member.isStreaming || index > 0 { Divider() }
                CurrentActivityCard(
                    activity: activity,
                    // **No buttons, deliberately.** Their addresses come from a
                    // route this client only asks for when a profile opens, and
                    // a button drawn before its URL lands opens nothing — see
                    // `CurrentActivityCard.buttons`. The card is the way in.
                    buttonURLs: [],
                    // **And no store button, for a second reason.** This whole
                    // flyout is `allowsHitTesting(false)` — it follows the
                    // pointer off a roster row — so a button drawn here could
                    // not be pressed. `INVARIANTS.md` §5.5: a control that
                    // cannot work must not look like one that can.
                    storeOffers: [],
                    ground: .neutral,
                    openGame: nil,
                    applicationIconURL: model.applicationIconURL(
                        activity.applicationID, side: 68
                    ),
                    // The flyout is already one glass plate; a second inside it
                    // would be a card in a card.
                    platesItself: false
                )
            }
        }
        .padding(Spacing.snug)
        .frame(width: Self.width, alignment: .leading)
        // No material of its own: the popover's glass is the body — §4.9.
        .allowsHitTesting(false)
        // The row it hangs off already carries the whole of this for VoiceOver.
        .accessibilityHidden(true)
    }

    // MARK: The share

    private var share: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            HStack(spacing: Spacing.base) {
                Text("Streaming Now")
                    .font(Typeface.sectionHeader)
                    .foregroundStyle(Ink.tertiary)
                    .textCase(.uppercase)
                Spacer(minLength: Spacing.tight)
                LiveChip()
            }
            preview
        }
    }

    /// The frame itself.
    ///
    /// **A region with a fixed ratio, not a picture with a size.** The address
    /// arrives a moment after the card does and a stream that has just ended
    /// never sends one at all, so the box is reserved first and filled if it can
    /// be — otherwise the card would grow under the pointer the instant the
    /// answer landed. `INVARIANTS.md` §1.
    private var preview: some View {
        RemoteImage(
            url: member.streamKey.flatMap { model.streamPreviews[$0] },
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
        .frame(width: Self.previewSize.width, height: Self.previewSize.height)
        .clipShape(.rect(cornerRadius: Radius.chip, style: .continuous))
        .task(id: member.streamKey) {
            guard let key = member.streamKey else { return }
            // **A loop rather than a timer**, so it dies with the card: the task
            // is cancelled the moment the popover closes, which is the moment
            // the pointer leaves the row.
            while !Task.isCancelled {
                model.requestStreamPreview(key: key)
                try? await Task.sleep(for: Self.refresh)
            }
        }
    }

    // MARK: What they are doing

    /// Everything but the custom status, which the row's own chip already draws.
    private var activities: [Activity] {
        model.presences[member.id]?.activities?.list.filter { $0.kind != .custom } ?? []
    }
}
