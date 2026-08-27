import CoreGraphics
import Foundation
import WingcordCore

/// A request to say what an emoji or a sticker in a transcript actually is.
///
/// **The question every custom expression raises.** A message arrives carrying
/// a twenty-point picture of a cat with no words anywhere near it; the only
/// things a reader can ask are "what is it called" and "where is it from", and
/// until this existed there was nowhere to ask them.
///
/// One value on the store and one presenter at the window root — never a
/// `.popover` written into the drawn canvas, which cannot host one at all.
struct ExpressionInfoRequest: Equatable, Identifiable {
    enum Subject: Equatable {
        case emoji(EmojiRef)
        case sticker(StickerRef)
    }

    var subject: Subject
    /// The frame of the picture that was clicked, in window-root space, so the
    /// card appears beside it rather than at the pointer.
    var anchor: CGRect

    /// Stable per subject, so clicking the same emoji twice does not re-present.
    var id: String {
        switch subject {
        case .emoji(let emoji): "e\(emoji.id?.rawValue.description ?? emoji.name)"
        case .sticker(let sticker): "s\(sticker.id)"
        }
    }
}

/// Everything the card draws, resolved once against the store.
struct ExpressionInfo: Equatable, Sendable {
    /// The picture, at card size.
    var artURL: URL?
    /// Whether the art is a vector animation, which lives in the filmstrip cache
    /// rather than the still one.
    var isVector: Bool
    /// The Unicode glyph, for an emoji that has no picture to fetch.
    var glyph: String?
    /// `:shortcode:` for an emoji, the plain name for a sticker — a sticker is
    /// picked by name and has no shortcode, so wrapping one in colons would
    /// invent a syntax that does not work if anybody typed it.
    var title: String
    /// The sentence under the title. What this expression *is*, in the reader's
    /// terms.
    var detail: String
    /// Where it came from, when that is a server this account can name.
    var source: Source?

    /// One picture in the source strip.
    ///
    /// A URL and a flag rather than the emoji or sticker it came from: the strip
    /// draws both kinds identically, and the only thing it needs to know is
    /// which cache answers — a Lottie sticker has no bitmap on the CDN at all.
    struct Sample: Hashable, Sendable, Identifiable {
        var url: URL?
        var isVector: Bool

        var id: String { url?.absoluteString ?? "" }
    }

    struct Source: Equatable, Sendable {
        var guildID: GuildID?
        var name: String
        var iconURL: URL?
        var monogram: String
        /// What the server says about itself. Only for a server the reader can
        /// look at — see `EmojiSource.Guild.isPublic`.
        var description: String?
        /// Online and member counts, when the server publishes them.
        var onlineCount: Int?
        var memberCount: Int?
        /// The mark Discord grants it.
        var standing: GuildProfile.Standing?
        /// A strip of the server's other expressions.
        ///
        /// A picture of what a place is *like* answers "should I care about
        /// this" far better than a member count does — and it is free, since
        /// both source routes send them beside everything else.
        var sample: [Sample] = []
        /// Whether the reader is already in it, which decides whether the row
        /// is a destination or a statement.
        var isJoined: Bool
        /// Whether the source is still being fetched, so the card can say it is
        /// working rather than saying nothing.
        var isLoading: Bool = false
    }
}
