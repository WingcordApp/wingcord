import Foundation

/// The sentence Discord composes for a message nobody typed.
///
/// A join, a boost, a pin and a call are all real rows in a transcript with
/// **empty content** — the words are the client's, not the sender's. A renderer
/// that only knows how to draw `content` draws an avatar, a name, a timestamp
/// and a blank space, which is indistinguishable from a message that failed to
/// load. On a `#welcome` channel that is the entire channel.
///
/// The sentence comes back in pieces rather than one string, because the
/// member's name in the middle is drawn in their role colour and opens their
/// profile, and a stage's topic at the end is drawn bold. Interpolating them
/// into a finished string throws away the ranges anything downstream needs.
public struct SystemSentence: Hashable, Sendable {
    public var prefix: String
    /// The member's name, drawn in their colour and clickable. Empty for events
    /// that name nobody.
    public var name: String
    public var suffix: String
    /// Drawn bold after the suffix — Discord's `$b` run, the topic a stage
    /// started, ended or changed to. Empty for every other sentence.
    public var emphasis = ""
    /// The SF Symbol drawn in the gutter where an avatar would be.
    public var symbolName: String
    /// What the glyph is tinted with.
    public var tint: Tint

    public enum Tint: Hashable, Sendable {
        case affirmative
        case quiet
        case celebratory
        case destructive
    }
}

public enum SystemMessageText {

    /// Discord's own welcome lines, in Discord's own order.
    ///
    /// **The order is load-bearing**, because the line for a given message is
    /// chosen by its timestamp modulo this count — so the sentence under
    /// somebody's join is stable across clients, across sessions and across
    /// re-fetches. Reordering this array silently rewrites the history of a
    /// `#welcome` channel.
    static let joinLines: [(prefix: String, suffix: String)] = [
        ("", " joined the party."),
        ("", " is here."),
        ("Welcome, ", ". We hope you brought pizza."),
        ("A wild ", " appeared."),
        ("", " just landed."),
        ("", " just slid into the server."),
        ("", " just showed up!"),
        ("Welcome ", ". Say hi!"),
        ("", " hopped into the server."),
        ("Everyone welcome ", "!"),
        ("Glad you're here, ", "."),
        ("Good to see you, ", "."),
        ("Yay you made it, ", "!"),
    ]

    /// The row for a system message, or nil for a kind that is drawn normally.
    ///
    /// - Parameters:
    ///   - name: What to call the author — the member's nickname where they have
    ///     one, since that is the name the rest of the transcript uses.
    ///   - subject: The person an event was done *to*, where there is one — the
    ///     member added to or removed from a group.
    public static func sentence(
        for message: Message,
        name: String,
        subject: String? = nil
    ) -> SystemSentence? {
        switch message.kind {
        case .userJoin:
            // Modulo the millisecond timestamp, which is Discord's own
            // selection. The snowflake already carries it, so there is nothing
            // to store and nothing that can drift.
            let milliseconds = UInt64(message.id.timestamp.timeIntervalSince1970 * 1000)
            let line = joinLines[Int(milliseconds % UInt64(joinLines.count))]
            return SystemSentence(
                prefix: line.prefix,
                name: name,
                suffix: line.suffix,
                symbolName: "arrow.right",
                tint: .affirmative
            )

        case .guildBoost:
            return SystemSentence(
                prefix: "", name: name, suffix: " just boosted the server!",
                symbolName: "sparkles", tint: .celebratory
            )
        case .guildBoostTier1, .guildBoostTier2, .guildBoostTier3:
            let level = message.kind == .guildBoostTier1
                ? 1 : (message.kind == .guildBoostTier2 ? 2 : 3)
            return SystemSentence(
                prefix: "",
                name: name,
                suffix: " just boosted the server! It has achieved Level \(level)!",
                symbolName: "sparkles",
                tint: .celebratory
            )

        case .pollResult:
            // **The sentence carries the question and the winner, because the
            // row has nothing else.** A `POLL_RESULT` message has empty content
            // and an embed nobody draws — so without this it is an author line
            // over a blank space, which is exactly what a closed poll looked
            // like in this transcript.
            guard let result = message.pollResult else {
                return SystemSentence(
                    prefix: "", name: name, suffix: "'s poll has closed.",
                    symbolName: "chart.bar.fill", tint: .quiet
                )
            }
            let outcome: String
            if let winner = result.winner, result.totalVotes > 0 {
                let percent = Int((result.share * 100).rounded())
                outcome = " \u{201C}\(winner)\u{201D} won with \(percent)%."
            } else {
                // A poll can close with nobody having voted, and saying a winner
                // won with 0% is a claim the wire did not make.
                outcome = " Nobody voted."
            }
            return SystemSentence(
                prefix: "",
                name: name,
                suffix: "'s poll \u{201C}\(result.question)\u{201D} has closed.\(outcome)",
                symbolName: "chart.bar.fill",
                tint: .quiet
            )

        case .channelPinnedMessage:
            return SystemSentence(
                prefix: "", name: name, suffix: " pinned a message to this channel.",
                symbolName: "pin.fill", tint: .quiet
            )
        case .channelNameChange:
            return SystemSentence(
                prefix: "", name: name,
                suffix: message.content.isEmpty
                    ? " changed the channel name."
                    : " changed the channel name: \(message.content)",
                symbolName: "pencil", tint: .quiet
            )
        case .channelIconChange:
            return SystemSentence(
                prefix: "", name: name, suffix: " changed the channel icon.",
                symbolName: "photo", tint: .quiet
            )
        case .channelFollowAdd:
            return SystemSentence(
                prefix: "", name: name,
                suffix: message.content.isEmpty
                    ? " added a channel to this one."
                    : " added \(message.content) to this channel.",
                symbolName: "megaphone.fill", tint: .quiet
            )
        case .threadCreated:
            return SystemSentence(
                prefix: "", name: name,
                suffix: message.content.isEmpty
                    ? " started a thread."
                    : " started a thread: \(message.content)",
                symbolName: "text.bubble", tint: .quiet
            )

        case .recipientAdd:
            return SystemSentence(
                prefix: "", name: name,
                suffix: subject.map { " added \($0) to the group." } ?? " added someone to the group.",
                symbolName: "person.badge.plus", tint: .affirmative
            )
        case .recipientRemove:
            // Leaving and being removed are the same wire kind and read very
            // differently, so the two are distinguished by whether the subject
            // is the author.
            let isDeparture = subject == nil || subject == name
            return SystemSentence(
                prefix: "", name: name,
                suffix: isDeparture
                    ? " left the group."
                    : " removed \(subject ?? "someone") from the group.",
                symbolName: "person.badge.minus", tint: .destructive
            )
        case .call:
            return SystemSentence(
                prefix: "", name: name, suffix: " started a call.",
                symbolName: "phone.fill", tint: .quiet
            )

        // A stage's own lines (`Rv+TSM`, `zla/ux`, `dKW5C+`, `tv2DNy`,
        // `Yy6vLs`), each with the topic from `content` in bold. Discord tints
        // only the start's stage mark, green.
        case .stageStart:
            return SystemSentence(
                prefix: "", name: name, suffix: " started ", emphasis: message.content,
                symbolName: "person.wave.2.fill", tint: .affirmative
            )
        case .stageEnd:
            return SystemSentence(
                prefix: "", name: name, suffix: " ended ", emphasis: message.content,
                symbolName: "person.wave.2.fill", tint: .quiet
            )
        case .stageSpeaker:
            return SystemSentence(
                prefix: "", name: name, suffix: " is now a speaker.",
                symbolName: "mic.fill", tint: .quiet
            )
        case .stageRaiseHand:
            return SystemSentence(
                prefix: "", name: name, suffix: " requested to speak.",
                symbolName: "hand.raised.fill", tint: .quiet
            )
        case .stageTopic:
            return SystemSentence(
                prefix: "", name: name, suffix: " changed the Stage topic: ",
                emphasis: message.content,
                symbolName: "person.wave.2.fill", tint: .quiet
            )
        case .default, .reply, .chatInputCommand, .contextMenuCommand,
             .threadStarterMessage, .unknown:
            // Not a system event: these carry something somebody wrote.
            return nil
        case .autoModerationAction:
            // AutoMod's own card — see `AutoModMessage`.
            return nil
        }
    }
}
