import Foundation

// MARK: - A custom typing indicator
//
// Discord's `discord_protos.users.v1.UserTypingIndicatorStyle` (web build
// 641803, modules 441574 and 870600): up to three emoji in place of the dots,
// the way they move, and the word in place of "typing" — "is yapping…". A
// Nitro perk set from the profile, carried as `typing_indicator_style` on every
// `TYPING_START` and on the account's own user object.
//
// **Discord's desktop client stores it and never draws it** — its store's
// `getCustomTypingIndicatorConfig` has no caller; only mobile shows it. Wingcord
// draws it (docs/CLIPS-PRESENCE.md §2.8, D23), and like Discord's FAQ says of
// mobile, only while one person types: with two or more the line is the plain one.

public struct TypingIndicatorStyle: Hashable, Sendable, Codable {

    /// How the emoji move — `TypingIndicatorAnimation`.
    public enum Animation: Int, Hashable, Sendable, CaseIterable, Codable {
        case unspecified = 0
        case pulse = 1
        case ring = 2
        case wave = 3

        /// The picker's name for it, Discord's own strings.
        public var title: String {
            switch self {
            case .unspecified: "None"
            case .pulse: "Pulse"
            case .ring: "Ring"
            case .wave: "Wave"
            }
        }
    }

    /// The word in place of "typing" — `TypingSuggestion`. Discord's strings
    /// already carry chirping, keysmashing, purring and thinking with no number
    /// yet; a number this client does not know reads as plain typing.
    public enum Suggestion: Int, Hashable, Sendable, CaseIterable, Codable {
        case unspecified = 0
        case yapping = 1
        case venting = 2
        case oversharing = 3
        case barking = 4
        case babbling = 5
        case daydreaming = 6
        case meowing = 7

        /// "yapping" — what follows "is". Unspecified is plain "typing".
        public var verb: String {
            switch self {
            case .unspecified: "typing"
            case .yapping: "yapping"
            case .venting: "venting"
            case .oversharing: "oversharing"
            case .barking: "barking"
            case .babbling: "babbling"
            case .daydreaming: "daydreaming"
            case .meowing: "meowing"
            }
        }
    }

    /// Discord's picker has three slots.
    public static let emojiLimit = 3

    /// In order; a custom one by id, with `name` empty — the wire carries only
    /// the id and whether it moves.
    public var emojis: [EmojiRef]
    public var animation: Animation
    public var suggestion: Suggestion

    public init(emojis: [EmojiRef] = [], animation: Animation = .unspecified, suggestion: Suggestion = .unspecified) {
        self.emojis = Array(emojis.prefix(Self.emojiLimit))
        self.animation = animation
        self.suggestion = suggestion
    }

    /// From the wire's numbers, an unknown one read as unspecified.
    public init(emojis: [EmojiRef], animationValue: Int?, suggestionValue: Int?) {
        self.init(
            emojis: emojis,
            animation: animationValue.flatMap(Animation.init(rawValue:)) ?? .unspecified,
            suggestion: suggestionValue.flatMap(Suggestion.init(rawValue:)) ?? .unspecified
        )
    }

    /// Nothing chosen: the plain indicator, which the account stores as null.
    public var isPlain: Bool {
        emojis.isEmpty && animation == .unspecified && suggestion == .unspecified
    }

    /// Discord's "Surprise Me": a way of moving and a word at random — the
    /// emoji stay the reader's own.
    public func surprised<G: RandomNumberGenerator>(using generator: inout G) -> TypingIndicatorStyle {
        var style = self
        style.animation = [Animation.pulse, .ring, .wave].randomElement(using: &generator) ?? .pulse
        style.suggestion = Suggestion.allCases.filter { $0 != .unspecified }
            .randomElement(using: &generator) ?? .yapping
        return style
    }
}

/// The line under the transcript that says who is typing.
public enum TypingSentence {

    /// "Ana is yapping…", "Ana and Ben are typing…", "Ana, Ben and Cai are
    /// typing…", or past three, "Several people are typing…" — a list of five
    /// nicknames is longer than the composer and says less.
    ///
    /// - Parameter style: the one typer's own; ignored for more than one.
    public static func make(names: [String], style: TypingIndicatorStyle?) -> String {
        switch names.count {
        case 0: ""
        case 1: "\(names[0]) is \((style?.suggestion ?? .unspecified).verb)\u{2026}"
        case 2: "\(names[0]) and \(names[1]) are typing\u{2026}"
        case 3: "\(names[0]), \(names[1]) and \(names[2]) are typing\u{2026}"
        default: "Several people are typing\u{2026}"
        }
    }

    /// The style to draw: the one typer's, when they have one — none with two
    /// or more, as on Discord's mobile clients.
    public static func drawnStyle(typers: Int, style: TypingIndicatorStyle?) -> TypingIndicatorStyle? {
        guard typers == 1, let style, !style.isPlain else { return nil }
        return style
    }
}
