import Foundation
import WingcordCore

/// `typing_indicator_style`, as `TYPING_START` and the account carry it and as
/// `PATCH /users/@me` takes it — Discord's module `870600` both ways:
///
/// ```json
/// {"emojis":[{"custom_emoji_id":"…","animated":true},{"unicode_emoji":"❤️"}],
///  "animation":3,"typing_suggestion":1}
/// ```
///
/// A custom emoji arrives as its id and whether it moves, never its name; the
/// write sends the id alone.
struct TypingIndicatorStyleDTO: Codable, Sendable {
    struct Emoji: Codable, Sendable {
        var custom_emoji_id: String?
        var animated: Bool?
        var unicode_emoji: String?
    }

    var emojis: [Emoji]?
    var animation: Int?
    var typing_suggestion: Int?

    var domain: TypingIndicatorStyle {
        TypingIndicatorStyle(
            emojis: (emojis ?? []).compactMap { emoji in
                if let id = emoji.custom_emoji_id.flatMap(EmojiID.init) {
                    return EmojiRef(id: id, name: "", isAnimated: emoji.animated ?? false)
                }
                guard let unicode = emoji.unicode_emoji, !unicode.isEmpty else { return nil }
                return EmojiRef(name: unicode)
            },
            animationValue: animation,
            suggestionValue: typing_suggestion
        )
    }

    /// The write's shape: `{custom_emoji_id}` or `{unicode_emoji}` per emoji.
    init(_ style: TypingIndicatorStyle) {
        emojis = style.emojis.map { emoji in
            emoji.id.map { Emoji(custom_emoji_id: String($0.rawValue)) } ?? Emoji(unicode_emoji: emoji.name)
        }
        animation = style.animation.rawValue
        typing_suggestion = style.suggestion.rawValue
    }
}
