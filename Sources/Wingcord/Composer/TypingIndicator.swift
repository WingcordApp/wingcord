import SwiftUI
import WingcordCore

/// Reads the store and works out who is still typing.
///
/// **Expiry is driven by one sleeping task, never by a ticking timer.** Discord
/// gives an indicator ten seconds and sends no "stopped" event, so somebody who
/// closes their tab mid-word would otherwise be typing forever. A one-second
/// poll would wake the CPU sixty times a minute in every channel to answer a
/// question that changes at most twice; instead the view sleeps until the
/// *earliest* expiry it can see, wakes once, and re-reads the clock. With nobody
/// typing there is no task at all.
struct TypingIndicatorContainer: View {
    var channelID: ChannelID

    @Environment(AppModel.self) private var model
    /// Bumped when an indicator lapses. Read by the body so that the recomputed
    /// `Date()` below actually reaches the screen.
    @State private var expiryTick: UInt64 = 0

    var body: some View {
        let _ = expiryTick
        let now = Date()
        TypingIndicator(names: names(at: now))
            .task(id: nextExpiry(after: now)) {
                guard let deadline = nextExpiry(after: Date()) else { return }
                let interval = deadline.timeIntervalSinceNow
                guard interval > 0 else { return }
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                expiryTick &+= 1
            }
    }

    /// Who is typing, named the way the transcript names them.
    ///
    /// The reader is excluded: an indicator that reports your own keystrokes
    /// back at you is a control that describes itself.
    private func names(at now: Date) -> [String] {
        guard let typing = model.messages(in: channelID)?.typing, !typing.isEmpty else {
            return []
        }
        let guildID = model.channelIndex.guildID(of: channelID)
        var result: [String] = []
        result.reserveCapacity(typing.count)
        for (userID, expiry) in typing where expiry > now && userID != model.currentUserID {
            guard let user = model.users[userID] else { continue }
            let member = guildID.flatMap { model.members[$0]?[userID] }
            result.append(member?.resolvedName(user: user) ?? user.preferredName)
        }
        // Sorted so a flush that reorders a dictionary does not reshuffle the
        // sentence under the reader's eyes.
        result.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        return result
    }

    private func nextExpiry(after now: Date) -> Date? {
        guard let typing = model.messages(in: channelID)?.typing else { return nil }
        var earliest: Date?
        for expiry in typing.values where expiry > now {
            if earliest == nil || expiry < earliest! { earliest = expiry }
        }
        return earliest
    }
}

/// The line above the composer: who is typing right now.
///
/// **It reserves no height when nobody is.** A permanent strip is a permanent
/// tax on the transcript's own inset — the composer is measured and the
/// transcript insets to match, so an always-present empty row would push every
/// message up a line for a state that is usually false.
///
/// The dots are an animated SF Symbol rather than three shapes on a repeating
/// spring. A `symbolEffect` is driven by the system's own animation server: it
/// costs no view invalidation, no body evaluation and no timer of its own, which
/// is the entire objection to hand-rolling this — an indicator that runs a
/// display link is a display link running in every open channel.
struct TypingIndicator: View, Equatable {
    var names: [String]

    static func == (lhs: TypingIndicator, rhs: TypingIndicator) -> Bool {
        lhs.names == rhs.names
    }

    @Environment(\.motion) private var motion

    var body: some View {
        Group {
            if !names.isEmpty {
                HStack(spacing: Spacing.base) {
                    dots
                    Text(sentence)
                        .font(Typeface.rowSubtitle)
                        // Fixed white rather than the hierarchy: this floats
                        // over the transcript, so a `.secondary` line resolves
                        // against whatever message happens to be scrolling under
                        // it — which is exactly how it got lost.
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                // **A pill, not a line of text over the scrollback.** Bare text
                // laid over a moving transcript has no ground of its own, so it
                // reads as part of whatever message is passing behind it — a
                // nickname in bold slides under "is typing" and the whole line
                // becomes unreadable. The pill gives it an edge and a material,
                // and it is the composer's own so the two read as one object.
                .padding(.horizontal, Spacing.snug)
                .padding(.vertical, 5)
                .glassEffect(.clear.tint(Palette.flyoutTint), in: .capsule)
                .padding(.leading, Spacing.margin)
                .padding(.bottom, Spacing.tight)
                .transition(.materialize(from: .bottom))
            }
        }
        // Leading, and hugging: the pill is as wide as its sentence, so a
        // full-width bar does not sit over the transcript saying nothing.
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(motion.fadeQuick, value: names)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(names.isEmpty ? "" : sentence))
    }

    @ViewBuilder
    private var dots: some View {
        let glyph = Image(systemName: "ellipsis")
            .font(.system(.caption, weight: .bold))
            .foregroundStyle(.white.opacity(0.7))
        if motion.reduceMotion {
            // Reduce Motion removes the movement, not the meaning: the dots stay
            // and stop pulsing.
            glyph
        } else {
            glyph.symbolEffect(.variableColor.iterative.hideInactiveLayers)
        }
    }

    /// The sentence, in the shape people actually read.
    ///
    /// Two names are joined with "and"; past three it stops naming anybody,
    /// because a list of five nicknames is longer than the composer and says
    /// less than "several people" does.
    private var sentence: String {
        switch names.count {
        case 1: "\(names[0]) is typing…"
        case 2: "\(names[0]) and \(names[1]) are typing…"
        case 3: "\(names[0]), \(names[1]) and \(names[2]) are typing…"
        default: "Several people are typing…"
        }
    }
}
