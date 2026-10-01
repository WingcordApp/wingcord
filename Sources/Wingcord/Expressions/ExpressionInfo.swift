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

/// What a sticker nobody's server owns turned out to be.
///
/// **A message cannot say.** Its `sticker_items` carry an id, a name and a
/// format; one of Discord's own and a server's look the same there. The packs
/// Discord still offers answer most clicks with no request at all, and
/// `GET /stickers/{id}` answers the rest — see `SessionController.resolveSticker`.
enum StickerLookup: Equatable, Sendable {
    /// Still being asked.
    case resolving
    /// One of Discord's own. `isOffered` is false for a pack Discord no longer
    /// lists, which its card names and says is no longer available.
    case standard(StickerPack, isOffered: Bool)
    /// One of Discord's own, whose pack could not be fetched.
    case standardUnnamed
    /// A server's sticker; the source route says which server.
    case guildSticker
    /// Nothing answered. The card falls back to what it can honestly say.
    case failed
}

/// The composer's sticker picker, asked for at one pack.
///
/// A token beside the pack, for `ExpressionJump`'s reason: asking for the same
/// pack twice is two requests, not one state.
struct StickerPickerRequest: Equatable, Sendable {
    var channelID: ChannelID
    /// The picker section to open at — `ExpressionSection.id`.
    var sectionID: String
    var token: Int
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
    /// The sticker itself, when the card is about one — so the art can play
    /// whatever format it is in rather than only a `.gif`.
    var sticker: StickerRef? = nil
    /// The pack, when the sticker is one of Discord's own.
    var pack: Pack? = nil

    /// One of Discord's own sticker packs, as its card shows it.
    struct Pack: Equatable, Sendable {
        /// The picker section the pack is filed under, for View More Stickers.
        var sectionID: String
        var name: String
        /// False for a pack Discord no longer offers.
        var isOffered: Bool
        /// Up to three more from the pack — Discord's own pick: the pack's
        /// first four, without the one that was clicked.
        var samples: [StickerRef]
    }

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
        var mark: GuildMark?
        /// A strip of the server's other expressions.
        ///
        /// A picture of what a place is *like* answers "should I care about
        /// this" far better than a member count does — and it is free, since
        /// both source routes send them beside everything else.
        var sample: [Sample] = []
        /// Whether the reader is already in it, which decides whether the row
        /// is a destination or a statement.
        var isJoined: Bool
        /// Open to be looked at from outside — `DISCOVERABLE` — which is what
        /// offers Join Server for one the reader is not in.
        var isDiscoverable = false
        /// Whether the source is still being fetched, so the card can say it is
        /// working rather than saying nothing.
        var isLoading: Bool = false
    }
}
