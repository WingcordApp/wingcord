import SwiftUI
import WingcordCore

/// Who is in a voice channel, drawn beneath its row.
///
/// **A list of people, nested under a list of rooms.** Every element is one step
/// quieter than the channel above it — a smaller face, a smaller name, a lighter
/// ink — so the strip reads as belonging to its row rather than competing with
/// the rows around it.
///
/// The rows are static text and images; the only thing here that reaches
/// anything is the flyout, and it is built inside the popover's own closure so a
/// strip nobody is pointing at costs no store reads at all.
struct VoiceMemberStrip: View {
    var members: [VoiceMemberChip]
    /// The room they are in, for the flyout's join line.
    var channelID: ChannelID
    var guildID: GuildID?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(members) { member in
                VoiceMemberRow(member: member, channelID: channelID, guildID: guildID)
            }
        }
    }
}

/// One person in that strip.
private struct VoiceMemberRow: View {
    var member: VoiceMemberChip
    var channelID: ChannelID
    var guildID: GuildID?

    @Environment(\.motion) private var motion
    @State private var isHovering = false
    /// The dwell before the flyout opens, as a cancelled task rather than a
    /// timer — the same shape `HoverFlyout` uses, and for the same reason:
    /// sweeping down a server's voice channels crosses forty of these in half a
    /// second, and a card per crossing is forty windows.
    @State private var dwell: Task<Void, Never>?
    @State private var isFlyoutShown = false

    /// Long enough that crossing a row on the way somewhere else shows nothing.
    /// Longer than the rail's, because this card is bigger and fetches a
    /// picture.
    private static let dwellDuration = Duration.milliseconds(320)

    var body: some View {
        HStack(spacing: Spacing.tight + 2) {
            avatar
            Text(member.name)
                .font(Typeface.voiceMemberName)
                .foregroundStyle(isHovering ? Ink.secondary : Ink.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)

            if member.statusEmoji != nil || member.statusText != nil {
                VoiceStatusChip(emoji: member.statusEmoji, text: member.statusText)
            }

            Spacer(minLength: Spacing.tight)

            if member.hasAccessories { accessories }
        }
        .padding(.horizontal, Spacing.tight)
        .frame(height: Metrics.voiceMemberRowHeight)
        .contentShape(.rect(cornerRadius: Radius.chip))
        .background {
            RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                .fill(Palette.hoverFill)
                .opacity(isHovering ? 1 : 0)
        }
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
            dwell?.cancel()
            guard hovering else {
                dwell = nil
                if isFlyoutShown { isFlyoutShown = false }
                return
            }
            // Nothing to say about somebody who is only sitting there. The card
            // exists to show a share or an activity, and an empty one is a
            // window that opens to say nothing.
            guard member.isStreaming || member.gameIconURL != nil else { return }
            dwell = Task {
                try? await Task.sleep(for: Self.dwellDuration)
                guard !Task.isCancelled else { return }
                isFlyoutShown = true
            }
        }
        .animation(motion.hover, value: isHovering)
        .popover(
            isPresented: Binding(
                get: { isFlyoutShown },
                // Dismissal belongs to the pointer leaving. Clearing here too
                // would fight `onHover` and flicker.
                set: { if !$0 { isFlyoutShown = false } }
            ),
            arrowEdge: .trailing
        ) {
            VoiceMemberFlyout(member: member, channelID: channelID, guildID: guildID)
                // The popover's glass is the card's body — §4.9.
                .presentationBackground(.clear)
        }
        // One node for the row. Deriving a label from five views is the
        // permanent accessibility tax `INVARIANTS.md` §2 is about, and this
        // strip has forty rows in it.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabel))
    }

    /// The face, with a ring while they are talking.
    ///
    /// **The ring is an overlay rather than a border**, so it does not change
    /// the avatar's size — a ring that grew the face would reflow the whole
    /// strip every time somebody started a sentence.
    private var avatar: some View {
        AvatarView(
            url: member.avatarURL,
            monogram: member.monogram,
            side: Metrics.avatarVoiceRow
        )
        .overlay {
            Circle()
                .strokeBorder(Palette.presenceOnline, lineWidth: 2)
                .opacity(member.isSpeaking ? 1 : 0)
        }
        .animation(motion.fadeQuick, value: member.isSpeaking)
    }

    /// What is true about them, at the row's trailing edge.
    ///
    /// The order is Discord's, and it is an order of urgency: the share is the
    /// thing you might want to open, the switches are what would stop a
    /// conversation, and the game is context.
    private var accessories: some View {
        HStack(spacing: Spacing.tight) {
            if member.isStreaming { LiveChip() }
            if member.isMuted {
                Image(systemName: "mic.slash.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.destructive)
            }
            if member.isDeafened {
                Image(systemName: "headphones.slash")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.destructive)
            }
            if let url = member.gameIconURL {
                RemoteImage(url: url, side: Metrics.voiceGameMark) { Color.clear }
                    .frame(width: Metrics.voiceGameMark, height: Metrics.voiceGameMark)
                    .clipShape(.rect(cornerRadius: 4, style: .continuous))
            }
        }
        .accessibilityHidden(true)
    }

    private var accessibilityLabel: String {
        var parts = [member.name]
        if let text = member.statusText { parts.append(text) }
        if member.isStreaming { parts.append("live") }
        if member.isMuted { parts.append("muted") }
        if member.isDeafened { parts.append("deafened") }
        if let game = member.gameName { parts.append("playing \(game)") }
        return parts.joined(separator: ", ")
    }
}

/// The custom status somebody set, as the pill Discord puts after their name.
///
/// Either half may be absent: a status can be one emoji, or words with no
/// emoji, and the pill has to hold its shape for both.
private struct VoiceStatusChip: View {
    var emoji: EmojiRef?
    var text: String?

    private static let emojiSide: CGFloat = 12

    var body: some View {
        HStack(spacing: 3) {
            if let emoji { InlineEmojiMark(emoji: emoji, side: Self.emojiSide) }
            if let text {
                Text(text)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 5)
        .frame(height: 16)
        .background { Capsule().fill(Palette.hoverFill) }
        .fixedSize()
    }
}

/// The red chip that says somebody is sharing a screen.
struct LiveChip: View {
    var body: some View {
        Text("LIVE")
            .font(.system(size: 9, weight: .heavy))
            // Fixed white rather than the hierarchy: this sits on a saturated
            // red plate, which vibrancy has no useful answer for.
            .foregroundStyle(Color.white)
            .padding(.horizontal, 4)
            .frame(height: 15)
            .background { Capsule().fill(Palette.destructive) }
            .fixedSize()
    }
}

/// One emoji, custom or Unicode, at a given size.
///
/// **Shared by the status chip and the channel's own status line**, which is why
/// it is not private to either: the two draw the same thing at two sizes, and a
/// second copy is a second place for an animated emoji to be asked for as a
/// still.
struct InlineEmojiMark: View {
    var emoji: EmojiRef
    var side: CGFloat

    var body: some View {
        if let id = emoji.id {
            RemoteImage(
                url: CDN.emoji(id: id, animated: emoji.isAnimated, side: side),
                side: side
            ) { Color.clear }
            .frame(width: side, height: side)
        } else {
            Text(emoji.name)
                .font(.system(size: side))
                .lineLimit(1)
        }
    }
}

/// The label a voice channel is wearing, under its name.
///
/// **Runs, not a string.** A status may carry custom emoji in Discord's
/// `<:name:id>` markup, and the split is done once in the memo — see
/// `SidebarChannel.voiceStatus`. What arrives here is already the sequence to
/// draw, so the row builds one `Text` per run and scans nothing.
struct VoiceStatusLine: View {
    var runs: [VoiceChannelStatus.Run]

    private static let emojiSide: CGFloat = 12

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                switch run {
                case .text(let text):
                    Text(text)
                        .font(Typeface.voiceChannelStatus)
                        .foregroundStyle(Ink.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                case .emoji(let emoji):
                    InlineEmojiMark(emoji: emoji, side: Self.emojiSide)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// How long the session in a room has been running.
///
/// **A `TimelineView` on a one-second cadence, and only where there is a session
/// to time.** Nothing else in the sidebar has a clock in it, so this is the one
/// view in the column that redraws on its own — which is why it is the smallest
/// possible leaf: the label alone re-renders each second, not the row, not the
/// strip and not the list.
///
/// `SwiftUI.TimelineView` fully qualified: this app has a `TimelineView` of its
/// own and the unqualified name resolves to the message canvas.
struct VoiceSessionClock: View {
    var startedAt: Date

    var body: some View {
        SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(Self.elapsed(since: startedAt, at: context.date))
                .font(Typeface.voiceChannelClock)
                .foregroundStyle(Palette.presenceOnline)
        }
        .accessibilityHidden(true)
    }

    /// `h:mm:ss` over an hour, `m:ss` under it — the same shape the activity
    /// card's clock takes, because a reader who has learned one has learned
    /// both.
    static func elapsed(since startedAt: Date, at now: Date) -> String {
        ActivityCardContent.clock(Int(now.timeIntervalSince(startedAt)))
    }
}
