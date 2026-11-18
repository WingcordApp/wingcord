import SwiftUI
import WingcordCore

/// Reads the store and works out who is typing.
///
/// **No clock of its own.** Discord gives an indicator ten seconds and sends no
/// "stopped" event; the session's one expiry timer prunes the table when an
/// indicator lapses — see `SessionController.armTypingExpiry` — so what this
/// reads is already current and the view runs no task at all.
struct TypingIndicatorContainer: View {
    var channelID: ChannelID

    @Environment(AppModel.self) private var model

    var body: some View {
        let typers = self.typers
        TypingIndicator(
            names: typers.map(\.name),
            // Their own indicator only while they type alone — with two or
            // more, the plain one, as on Discord's mobile clients.
            style: AppSettings.shared.drawsCustomTypingIndicators
                ? TypingSentence.drawnStyle(
                    typers: typers.count,
                    style: typers.first.flatMap { model.typingStyle(of: $0.id) }
                )
                : nil
        )
    }

    /// Who is typing, named the way the transcript names them.
    ///
    /// The reader is excluded: an indicator that reports your own keystrokes
    /// back at you is a control that describes itself.
    private var typers: [(id: UserID, name: String)] {
        let typing = model.typers(in: channelID)
        guard !typing.isEmpty else { return [] }
        let guildID = model.channelIndex.guildID(of: channelID)
        var result: [(id: UserID, name: String)] = []
        result.reserveCapacity(typing.count)
        // Nobody the reader has blocked or ignored: Discord's typing line asks
        // `isBlockedOrIgnored` of everyone in it, and a name here would be the
        // one place a silenced person still announced themselves.
        let blocked = model.blockedUserIDs
        let ignored = model.ignoredUserIDs
        for userID in typing.keys where userID != model.currentUserID {
            guard !blocked.contains(userID), !ignored.contains(userID) else { continue }
            guard let user = model.users[userID] else { continue }
            let member = guildID.flatMap { model.members[$0]?[userID] }
            result.append((userID, member?.resolvedName(user: user) ?? user.preferredName))
        }
        // Sorted so a flush that reorders a dictionary does not reshuffle the
        // sentence under the reader's eyes.
        result.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return result
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
    /// The one typer's custom indicator: their emoji in place of the dots and
    /// their word in place of "typing". Nil for the plain one.
    var style: TypingIndicatorStyle? = nil

    static func == (lhs: TypingIndicator, rhs: TypingIndicator) -> Bool {
        lhs.names == rhs.names && lhs.style == rhs.style
    }

    @Environment(\.motion) private var motion

    var body: some View {
        Group {
            if !names.isEmpty {
                HStack(spacing: Spacing.base) {
                    if let style, !style.emojis.isEmpty {
                        TypingEmojiRow(style: style)
                    } else {
                        dots
                    }
                    Text(styledSentence)
                        .font(Typeface.rowSubtitle)
                        // The secondary ink, as Discord sets this line in its
                        // normal text colour rather than its brightest. A fixed
                        // ink, never the vibrant hierarchy: vibrancy resolves
                        // against whatever message is scrolling under it.
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                // **Text, not a pill** (Alex, 2026-11-18: "remove the pill
                // background ... making them text only like on discord"): the
                // dots and the sentence straight on the transcript's ground,
                // the names in bold as Discord sets them. The row is measured
                // into the transcript's inset, so at rest no message sits under
                // the words, and it lives in the composer's bar, which is what
                // the scroll edge effect keys off. The insets are the old
                // pill's, so the words have not moved.
                .padding(.horizontal, Spacing.snug)
                .padding(.vertical, 5)
                .padding(.leading, Spacing.margin)
                .padding(.bottom, Spacing.tight)
                .transition(.materialize(from: .bottom))
            }
        }
        // Leading, and hugging: the line is as wide as its sentence, so a
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
            .foregroundStyle(Ink.secondary)
        if motion.reduceMotion {
            // Reduce Motion removes the movement, not the meaning: the dots stay
            // and stop pulsing.
            glyph
        } else {
            glyph.symbolEffect(.variableColor.iterative.hideInactiveLayers)
        }
    }

    /// The sentence, in the shape people actually read — see `TypingSentence`:
    /// "is yapping…" for one typer who chose it; two names joined with "and";
    /// past three, nobody named.
    private var sentence: String {
        TypingSentence.make(names: names, style: style)
    }

    /// The sentence with each name in bold, as Discord sets it ("**Ana** and
    /// **Ben** are typing…"). The pieces say which runs are names, so a name
    /// is never hunted for inside the words around it.
    private var styledSentence: AttributedString {
        TypingSentence.pieces(names: names, style: style).reduce(into: AttributedString()) { line, piece in
            var run = AttributedString(piece.text)
            if piece.isName { run.inlinePresentationIntent = .stronglyEmphasized }
            line += run
        }
    }
}
