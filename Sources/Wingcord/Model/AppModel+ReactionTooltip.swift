import Foundation
import WingcordCore

/// What a reaction chip's tooltip says.
struct ReactionTooltipContent: Equatable, Sendable {
    /// "`:fire:` reacted by Ana, Bo, and 10 others."
    var sentence: ReactionTooltipText.Sentence
    /// A second line a super reaction chip may carry — see
    /// `AppModel.reactionTooltip(for:in:)`.
    var note: String?
}

extension AppModel {

    /// What the chip under the pointer says: who reacted, and for a super
    /// reaction whether the reader sent one or can.
    ///
    /// **The names come from the route, not from the gateway.** Discord asks
    /// `GET …/reactions/{emoji}?limit=3&type=…` when a tooltip opens — captured
    /// — and names the first three, less anybody the reader has blocked or
    /// ignored, with everybody else counted. The answer is kept per chip until
    /// the chip's count moves, so a tooltip shown twice over a chip nobody has
    /// touched since asks once.
    func reactionTooltip(for hover: ReactionHover, in channelID: ChannelID) async -> ReactionTooltipContent? {
        guard let reaction = message(hover.messageID, in: channelID)?.reactions
            .first(where: { $0.emoji.isSameReaction(as: hover.emoji) })
        else { return nil }
        let count = reaction.count(of: hover.kind)
        guard count > 0 else { return nil }

        let key = ReactorKey(messageID: hover.messageID, emoji: hover.emoji.reactionKey, kind: hover.kind)
        let reactors: [UserID]
        if let cached = reactorCache[key], cached.count == count {
            reactors = cached.users
        } else {
            guard let fetched = await sessionController.reactors(
                of: hover.emoji, kind: hover.kind, on: hover.messageID, in: channelID
            ) else { return nil }
            reactorCache[key] = (count, fetched)
            reactors = fetched
        }

        let guildID = channelIndex.guildID(of: channelID)
        let names = reactors
            .filter { !isBlocked($0) && !isIgnored($0) }
            .prefix(3)
            .map { voiceName(of: $0, inGuild: guildID) }
        guard let sentence = ReactionTooltipText.sentence(
            emojiName: ReactionTooltipText.name(of: hover.emoji),
            names: names,
            remaining: max(0, count - names.count),
            kind: hover.kind
        ) else { return nil }

        // Discord's second line on a super reaction. Its "Add Super Reaction"
        // link is not here: the chip beneath the tooltip is that control. And
        // its Nitro upsell becomes the one fact the upsell carries — why the
        // chip does not answer a click — without anything to buy.
        let note: String? = switch hover.kind {
        case .burst where reaction.isMineBurst: "You’ve sent this Super Reaction"
        case .burst where !hasNitro: "Super Reactions need Nitro."
        default: nil
        }
        return ReactionTooltipContent(sentence: sentence, note: note)
    }
}

/// Discord's tooltip sentences, from the en-US strings its reactions module
/// reads (`reactionTooltip1`, `…1N`, `…2`, `…2N`, `…3`, `…3N`, and their
/// `burst` twins) — and their `…Interactive` forms, which are the same words
/// with the count of the others made a link to the list of everybody.
nonisolated enum ReactionTooltipText {

    /// A sentence, split where Discord's link starts.
    struct Sentence: Equatable, Sendable {
        /// Everything before the others — or the whole sentence, when
        /// everybody who reacted is named.
        var lead: String
        /// "1,178 others": what opens the list.
        var others: String?

        var text: String { lead + (others ?? "") }
    }

    /// How the sentence names the emoji: `:name:` for a custom one, the
    /// primary shortcode for a Unicode one — Discord's `convertSurrogateToName`
    /// — or the glyph itself where there is no shortcode.
    static func name(of emoji: EmojiRef) -> String {
        if emoji.isCustom { return ":\(emoji.name):" }
        return UnicodeEmoji.shortcode(for: emoji.name).map { ":\($0):" } ?? emoji.name
    }

    /// The sentence, or nil when there is nobody to name — Discord shows no
    /// tooltip then either.
    ///
    /// **The count is grouped** — "1,178 others" — because the strings carry it
    /// as an ICU `#`, which formats; the sentence is English, so the grouping
    /// is too.
    static func sentence(
        emojiName: String,
        names: [String],
        remaining: Int,
        kind: ReactionKind
    ) -> Sentence? {
        let lead = "\(emojiName) \(kind == .burst ? "Super reacted by" : "reacted by")"
        let count = remaining.formatted(.number.locale(Locale(identifier: "en_US")))
        let others = remaining == 1 ? "1 other" : "\(count) others"
        switch (names.count, remaining > 0) {
        case (1, false): return Sentence(lead: "\(lead) \(names[0])")
        case (1, true): return Sentence(lead: "\(lead) \(names[0]) and ", others: others)
        case (2, false): return Sentence(lead: "\(lead) \(names[0]) and \(names[1])")
        case (2, true): return Sentence(lead: "\(lead) \(names[0]), \(names[1]), and ", others: others)
        case (3, false): return Sentence(lead: "\(lead) \(names[0]), \(names[1]), and \(names[2])")
        case (3, true): return Sentence(lead: "\(lead) \(names[0]), \(names[1]), \(names[2]), and ", others: others)
        default: return nil
        }
    }
}
