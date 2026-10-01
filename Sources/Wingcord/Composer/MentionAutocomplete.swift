import Foundation
import WingcordCore

/// The `@` and `#` completions, as a pure scan of what has been typed.
///
/// **Built on `EmojiAutocomplete`'s shape deliberately**, down to the method
/// names: three functions with no state, no store and no view, so the rule for
/// *what counts as a trigger* is one testable place rather than something the
/// composer decides while it is being typed into.
///
/// The three rules, and each of them is a real defect avoided:
///
///  - **A sigil that follows a word is part of that word.** `alex@example.com`
///    is not a mention and `C#` is not a channel. Only a sigil at the start of
///    the text or after whitespace opens a completion — the same test the
///    shortcode scanner makes for `:`.
///  - **A token containing whitespace has ended.** Somebody who typed
///    `@alex hello` is writing a sentence, not still choosing.
///  - **Only the LAST sigil counts**, because that is where the caret is. A
///    message that already names two people is not three open completions.
nonisolated enum MentionAutocomplete {

    /// What kind of thing is being completed.
    enum Kind: Hashable, Sendable {
        case member
        case channel
        /// After `@time ` — a moment, read from what follows. Discord's
        /// `timestampMentionInput`.
        case time
        /// After `@game ` — a game, searched for by what follows. Discord's
        /// `gameMentionInput`.
        case game

        var sigil: Character {
            switch self {
            case .member, .time, .game: "@"
            case .channel: "#"
            }
        }
    }

    /// A completion in progress: what is being looked for, and the text of it.
    struct Trigger: Hashable, Sendable {
        var kind: Kind
        /// What has been typed after the sigil, lowercased. Empty is a real
        /// state — a bare `@` opens the list on everybody, which is what
        /// Discord does and what makes the feature usable at all.
        var query: String
        /// How far into the text the sigil is.
        ///
        /// **Carried so the composer can settle a tie.** `:sob @al` has an
        /// open shortcode *and* an open mention by each scanner's own rules,
        /// and the one the reader is typing is whichever sigil is later. The
        /// two scanners cannot see each other, so the offset is what lets the
        /// surface above them decide. See `ComposerContainer`.
        var sigilOffset: Int
    }

    /// **Zero, not one.** A bare `@` is a valid trigger: the reader has said
    /// "somebody" and the list is how they say who. This differs from the
    /// shortcode scanner on purpose — a bare `:` is a colon, and there are
    /// thousands of emoji.
    static let minimumQueryLength = 0

    /// How many rows the list offers. Past a screenful the reader is scrolling
    /// rather than reading, and typing one more letter is faster.
    static let limit = 10

    /// The two words that open an input of their own, and what each opens.
    ///
    /// **Picking `@time` or `@game` writes the word and a space**, and typing
    /// them does the same — Discord's `autoInsertOnSpace` — so from there on
    /// everything up to the end of the line is what is being looked for, spaces
    /// and all: "tomorrow at 5pm", "grand theft auto".
    static let inputWords: [(word: String, kind: Kind)] = [("time", .time), ("game", .game)]

    /// What is being completed right now, or nil.
    static func trigger(in text: String) -> Trigger? {
        if let input = inputTrigger(in: text) { return input }
        // The later of the two sigils wins, because the caret is at the end of
        // the text and whichever was typed last is the one being answered.
        let candidates = [
            text.lastIndex(of: "@").map { (Kind.member, $0) },
            text.lastIndex(of: "#").map { (Kind.channel, $0) },
        ].compactMap { $0 }
        guard let (kind, sigil) = candidates.max(by: { $0.1 < $1.1 }) else { return nil }

        // A sigil that follows a word is part of that word — an email address,
        // a C# in a sentence, a colour hex.
        if sigil > text.startIndex {
            let before = text[text.index(before: sigil)]
            guard before.isWhitespace || before.isNewline else { return nil }
        }

        let token = text[text.index(after: sigil)...]
        guard token.count >= minimumQueryLength,
              !token.contains(where: { $0.isWhitespace || $0.isNewline })
        else { return nil }
        return Trigger(
            kind: kind,
            query: String(token).lowercased(),
            sigilOffset: text.distance(from: text.startIndex, to: sigil)
        )
    }

    /// `@time …` or `@game …` being filled in. The query is kept as typed —
    /// the time is read by a detector, and the list repeats it back.
    private static func inputTrigger(in text: String) -> Trigger? {
        guard let sigil = text.lastIndex(of: "@") else { return nil }
        if sigil > text.startIndex {
            let before = text[text.index(before: sigil)]
            guard before.isWhitespace || before.isNewline else { return nil }
        }
        let rest = text[text.index(after: sigil)...]
        for (word, kind) in inputWords {
            guard rest.count > word.count,
                  rest.prefix(word.count).lowercased() == word,
                  rest.dropFirst(word.count).first == " "
            else { continue }
            let query = rest.dropFirst(word.count + 1)
            guard !query.contains(where: \.isNewline) else { return nil }
            return Trigger(
                kind: kind,
                query: String(query.drop(while: { $0 == " " })),
                sigilOffset: text.distance(from: text.startIndex, to: sigil)
            )
        }
        return nil
    }

    /// Whether every character of `query` appears in `name`, in order —
    /// Discord's loose match for roles and the words `everyone` and `here`, so
    /// `nr` finds "new role". Both sides are expected lowercased.
    static func looselyMatches(_ query: String, _ name: String) -> Bool {
        var remaining = name[...]
        for wanted in query {
            guard let index = remaining.firstIndex(of: wanted) else { return false }
            remaining = remaining[remaining.index(after: index)...]
        }
        return true
    }

    /// The text with the trailing sigil and its token replaced.
    ///
    /// A trailing space follows, because a mention is the end of a word — the
    /// same reason the shortcode completion adds one.
    static func applying(_ replacement: String, kind: Kind, to text: String) -> String {
        guard let sigil = text.lastIndex(of: kind.sigil) else { return text }
        return text[..<sigil] + replacement + " "
    }
}

/// One row the `@` or `#` list offers.
///
/// **The token is carried rather than derived**, because the three kinds spell
/// themselves differently on the wire and only this type knows which is which:
/// a person is `<@id>`, a channel is `<#id>`, and `@everyone` is the literal
/// word. A view that rebuilt the token from a name would send text where a
/// mention was meant.
struct MentionCandidate: Hashable, Sendable, Identifiable {
    enum Art: Hashable, Sendable {
        /// A face.
        case avatar(URL?, monogram: String)
        /// A channel's own glyph — `#`, a speaker, a megaphone.
        case symbol(String)
        /// A game's icon, or a controller where it has none.
        case picture(URL?)
    }

    var id: String
    var art: Art
    /// What the row reads.
    var title: String
    /// The handle beside a person, or the category above a channel. Nil where
    /// there is nothing to say.
    var subtitle: String?
    /// What replaces the typed token.
    var token: String
    /// Their name's colour, where a role gave them one.
    var nameColor: UInt32?
    /// Which of Discord's three groups the row is in — people, then the
    /// mentions that are not a person (`@everyone`, `@here`, `@game`, `@time`),
    /// then roles. The list draws a rule where the group changes, as Discord's
    /// does.
    var group: Group = .person
    /// Whether picking the row finishes the mention, or opens the input it
    /// names — `@time` and `@game` write their word and wait.
    var opensInput = false

    enum Group: Hashable, Sendable {
        case person
        case global
        case role
        /// One reading in `@time`'s list, or `@game`'s results.
        case section(Int)
    }
}
