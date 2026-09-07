import Foundation

// The filter grammar as it is typed.
//
// **Captured** — the screenshots of Discord's own field — as `from: alexsample`,
// `mentions: alexsample`, `in: general`. The field is not a plain text box with
// filters bolted beside it: the tokens *are* the query, which is what lets the
// filter sheet and the field be one thing rather than two that drift.
//
// So the text is canonical. It is parsed on every change, the sheet writes
// canonical token text back into it, and nothing anywhere holds a second copy of
// "what is being searched".

/// A `key: value` pair in the search field.
public struct MessageSearchToken: Hashable, Sendable {

    /// The keys Discord's field accepts.
    ///
    /// **`in` is spelled `channel` in the enum** because `in` is a Swift keyword
    /// and a backticked case name would be quoted at every use site; `keyword`
    /// is what the field actually shows.
    public enum Kind: String, Hashable, Sendable, CaseIterable {
        case from, mentions, channel, has, pinned, before, after, during

        public var keyword: String {
            self == .channel ? "in" : rawValue
        }

        /// The prompt row's title and example, as the field's own menu shows
        /// them — "From a specific user / from: user".
        public var title: String {
            switch self {
            case .from: "From a specific user"
            case .mentions: "Mentions a specific user"
            case .channel: "Sent in a specific channel"
            case .has: "Includes a specific type of data"
            case .pinned: "Pinned or not pinned"
            case .before: "Sent before a date"
            case .after: "Sent after a date"
            case .during: "Sent on a date"
            }
        }

        public var example: String {
            switch self {
            case .from, .mentions: "\(keyword): user"
            case .channel: "in: channel"
            case .has: "has: link, embed or file"
            case .pinned: "pinned: true or false"
            case .before, .after, .during: "\(keyword): 2026-09-07"
            }
        }

        public var symbolName: String {
            switch self {
            case .from: "person"
            case .mentions: "at"
            case .channel: "number"
            case .has: "paperclip"
            case .pinned: "pin"
            case .before, .after, .during: "calendar"
            }
        }

        /// What a suggestion list for this key is drawn from.
        public var suggests: SuggestionSource {
            switch self {
            case .from, .mentions: .people
            case .channel: .channels
            case .has: .hasValues
            case .pinned: .booleans
            case .before, .after, .during: .dates
            }
        }

        public enum SuggestionSource: Hashable, Sendable {
            case people, channels, hasValues, booleans, dates
        }
    }

    public var kind: Kind
    /// What follows the colon, trimmed. Empty while somebody has typed `from:`
    /// and nothing else — which is the moment the whole list is offered.
    public var value: String

    public init(kind: Kind, value: String) {
        self.kind = kind
        self.value = value
    }

    /// How this token is written back into the field.
    ///
    /// **A space after the colon**, matching Discord's own rendering: `from:
    /// alexsample`. The parser accepts it with or without.
    public var text: String {
        "\(kind.keyword): \(value)"
    }
}

/// The search field's text, taken apart.
public struct MessageSearchTokenization: Hashable, Sendable {
    public var tokens: [MessageSearchToken]
    /// Everything that was not a `key: value` pair — the words actually being
    /// searched for.
    public var content: String
    /// The token being typed right now, if the text ends in one.
    ///
    /// **This is what a suggestion list is for.** `from:` with nothing after it
    /// offers everybody; `from: al` offers the matches. It is nil the moment a
    /// space is typed after a complete value, because the token is then finished
    /// and the next thing is a new word.
    public var editing: MessageSearchToken?

    public init(
        tokens: [MessageSearchToken] = [],
        content: String = "",
        editing: MessageSearchToken? = nil
    ) {
        self.tokens = tokens
        self.content = content
        self.editing = editing
    }
}

public enum MessageSearchTokenizer {

    /// Parses the field.
    ///
    /// **One pass, no regex, no allocation per character.** This runs on every
    /// keystroke of a field somebody types a sentence into, and a regex over the
    /// whole string per stroke is the kind of cost that never shows up in a
    /// profile as one line.
    ///
    /// `endsOpen` is the caller saying the caret is at the end of the text —
    /// true while typing. Only then can a trailing `key:` be the token being
    /// edited; a parse for *submission* passes false, so `from:` with nothing
    /// after it is dropped rather than sent as an empty filter.
    public static func parse(_ text: String, endsOpen: Bool = true) -> MessageSearchTokenization {
        var tokens: [MessageSearchToken] = []
        var words: [Substring] = []
        var editing: MessageSearchToken?

        // Whitespace-delimited: every value the field accepts is a handle, a
        // channel name, a keyword or a date, and none of them contains a space.
        //
        // The trailing space is kept as a *fact* rather than as an empty chunk:
        // `from: ` is still the token being typed — the caret is waiting for a
        // value — while `from: alex ` is finished and the next thing typed is a
        // new word. Dropping the empty chunk and remembering the space is what
        // tells those two apart.
        let endsWithSpace = text.last?.isWhitespace ?? false
        var chunks = text.split(
            omittingEmptySubsequences: false,
            whereSeparator: \.isWhitespace
        )
        while let last = chunks.last, last.isEmpty { chunks.removeLast() }

        var index = 0
        while index < chunks.count {
            let chunk = chunks[index]
            guard let colon = chunk.firstIndex(of: ":"),
                  let kind = Kind(String(chunk[chunk.startIndex..<colon]))
            else {
                if !chunk.isEmpty { words.append(chunk) }
                index += 1
                continue
            }

            var value = String(chunk[chunk.index(after: colon)...])
            // `from: alex` — the value is the next chunk when the colon ends
            // this one. Discord renders it with the space, so it has to parse.
            if value.isEmpty, index + 1 < chunks.count, !chunks[index + 1].isEmpty {
                index += 1
                value = String(chunks[index])
            }

            let token = MessageSearchToken(kind: kind, value: value)
            // The last chunk is the one the caret is in — unless a space has
            // been typed after a *complete* value, which finishes it.
            let isLast = index == chunks.count - 1
            if isLast, endsOpen, value.isEmpty || !endsWithSpace {
                editing = token
            } else {
                tokens.append(token)
            }
            index += 1
        }

        return MessageSearchTokenization(
            tokens: tokens,
            content: words.joined(separator: " "),
            editing: editing
        )
    }

    /// Replaces the token being typed with a chosen value, ready for the caret.
    ///
    /// Returns the whole field text, with a trailing space so the next word
    /// starts cleanly — which is what makes picking two filters in a row feel
    /// like one gesture rather than two.
    public static func completing(
        _ text: String,
        with token: MessageSearchToken
    ) -> String {
        var chunks = text.split(
            omittingEmptySubsequences: false,
            whereSeparator: \.isWhitespace
        ).map(String.init)

        // Drop the partial the caret is in — and the bare `key:` before it when
        // the value was being typed as its own chunk.
        while let last = chunks.last, last.isEmpty { chunks.removeLast() }
        if let last = chunks.last {
            if last.hasSuffix(":"), Kind(String(last.dropLast())) != nil {
                chunks.removeLast()
            } else if last.contains(":") {
                chunks.removeLast()
            } else if chunks.count >= 2, chunks[chunks.count - 2].hasSuffix(":"),
                      Kind(String(chunks[chunks.count - 2].dropLast())) != nil {
                chunks.removeLast(2)
            }
        }

        chunks.append(token.text)
        return chunks.joined(separator: " ") + " "
    }

    private typealias Kind = MessageSearchToken.Kind
}

private extension MessageSearchToken.Kind {
    /// Case-insensitive, because a field is typed in rather than chosen from.
    init?(_ keyword: String) {
        let folded = keyword.lowercased()
        if folded == "in" { self = .channel; return }
        guard let kind = MessageSearchToken.Kind(rawValue: folded), kind != .channel else {
            return nil
        }
        self = kind
    }
}
