import Foundation

/// One picture a post leads with on its board.
public struct ForumPostMedia: Hashable, Sendable {
    /// What to draw: a resized variant, or a video's poster frame. Never a video's
    /// own URL, which is not a picture.
    public var url: URL
    public var isSpoiler: Bool
    public var isVideo: Bool
    /// Whether it's a GIF, which Discord marks.
    public var isAnimated: Bool

    public init(url: URL, isSpoiler: Bool = false, isVideo: Bool = false, isAnimated: Bool = false) {
        self.url = url
        self.isSpoiler = isSpoiler
        self.isVideo = isVideo
        self.isAnimated = isAnimated
    }
}

/// What a post's row says about its opening message: Discord's rules for it, kept
/// apart from any view.
public enum ForumPostCard {

    /// A gallery draws this many and says how many more with a "+N".
    public static let mosaicLimit = 4

    /// Discord's `y` (`256265`): the opening message's attachments, then what its
    /// embeds lead with.
    ///
    /// **On a media channel the post's chosen thumbnail stands for all of it**
    /// (`L`), which is what the New Post card's thumbnail picker is for.
    ///
    /// - Parameters:
    ///   - width: the width it'll be drawn at, for the variant asked of the CDN.
    ///   - showsEmbeds: the reader's "Show embeds" setting.
    public static func media(
        of message: Message,
        isMediaChannel: Bool,
        width: CGFloat,
        showsEmbeds: Bool = true
    ) -> [ForumPostMedia] {
        let attachments = message.attachments.filter(isPictureOrVideo)
        if isMediaChannel, let thumbnail = attachments.first(where: \.isThumbnail) {
            return [media(of: thumbnail, width: width)].compactMap { $0 }
        }
        let fromFiles = attachments.compactMap { media(of: $0, width: width) }
        guard showsEmbeds else { return fromFiles }
        let hidesEmbeds = hasSpoilerLink(message.content)
        let fromEmbeds = message.embeds.compactMap { embed -> ForumPostMedia? in
            guard let lead = embed.image ?? embed.thumbnail ?? embed.galleryImages.first else { return nil }
            return media(of: lead, isSpoiler: hidesEmbeds, width: width)
        }
        return fromFiles + fromEmbeds
    }

    /// Discord's `m`/`T`: a picture it knows the size of, or a video it can get a
    /// poster for. Anything else is a file, and has no place on a board.
    public static func isPictureOrVideo(_ attachment: Attachment) -> Bool {
        if attachment.isVideo { return !attachment.proxyURL.isEmpty }
        guard attachment.isImage, let width = attachment.width, let height = attachment.height else { return false }
        return width > 0 && height > 0
    }

    private static func media(of attachment: Attachment, width: CGFloat) -> ForumPostMedia? {
        if attachment.isVideo {
            guard let poster = poster(ofVideoAt: attachment.proxyURL, width: width) else { return nil }
            return ForumPostMedia(url: poster, isSpoiler: attachment.isSpoiler, isVideo: true)
        }
        guard let url = CDN.resizedAttachment(
            proxyURL: attachment.proxyURL, width: width, sourceSize: attachment.pixelSize
        ) else { return nil }
        return ForumPostMedia(url: url, isSpoiler: attachment.isSpoiler, isAnimated: attachment.playsAsAnimated)
    }

    private static func media(of embed: Embed.Media, isSpoiler: Bool, width: CGFloat) -> ForumPostMedia? {
        let source = embed.proxyURL.flatMap { $0.isEmpty ? nil : $0 } ?? embed.url
        let isVideo = embed.isVideo || looksLikeVideo(source)
        if isVideo {
            guard let poster = poster(ofVideoAt: source, width: width) else { return nil }
            return ForumPostMedia(url: poster, isSpoiler: isSpoiler || embed.isSpoiler, isVideo: true)
        }
        guard let url = CDN.resizedAttachment(proxyURL: source, width: width, sourceSize: embed.pixelSize) else { return nil }
        return ForumPostMedia(url: url, isSpoiler: isSpoiler || embed.isSpoiler, isAnimated: embed.playsAsAnimated)
    }

    /// The CDN's still frame. A file that isn't on the CDN has none, except a
    /// picture standing in for a video on this Mac, which is what `--demo` has.
    private static func poster(ofVideoAt source: String, width: CGFloat) -> URL? {
        if let poster = CDN.videoPoster(proxyURL: source, width: width) { return poster }
        return source.hasPrefix("file:") ? URL(string: source) : nil
    }

    private static func looksLikeVideo(_ source: String) -> Bool {
        let path = source.prefix { $0 != "?" && $0 != "#" }.lowercased()
        return path.hasSuffix(".mp4") || path.hasSuffix(".webm") || path.hasSuffix(".mov")
    }

    /// Discord's `hasSpoilerEmbeds`: a link inside `||…||` keeps what it unfurls to
    /// covered too.
    ///
    /// By pairs, because that's what a spoiler is: a link between the end of one and
    /// the start of the next is out in the open.
    public static func hasSpoilerLink(_ content: String) -> Bool {
        guard content.contains("||") else { return false }
        let pieces = content.components(separatedBy: "||")
        // The odd pieces are inside, and the last one is only if something closes it.
        return stride(from: 1, to: pieces.count - 1, by: 2).contains { index in
            pieces[index].contains("http://") || pieces[index].contains("https://")
        }
    }

    /// The reaction a post's row shows: Discord's `lQ`, the most reactions of either
    /// kind, and among those the most super ones.
    public static func topReaction(of reactions: [Reaction]) -> Reaction? {
        // A stable pick, so a tie stays with the one Discord listed first.
        var best: Reaction?
        for reaction in reactions {
            guard let current = best else { best = reaction; continue }
            let total = reaction.count + reaction.burstCount
            let bestTotal = current.count + current.burstCount
            if total > bestTotal || (total == bestTotal && reaction.burstCount > current.burstCount) {
                best = reaction
            }
        }
        return best
    }

    /// Discord caps its "(N New)" here (`37411`'s `oR`).
    public static let unreadCap = 25

    /// How many messages to say are new, for a post with unread messages: Discord's
    /// `k6`. **"1+" when nobody has said how many**, which is a real state: the count
    /// comes from the gateway, on request, and only for what's on the board.
    ///
    /// - Parameters:
    ///   - count: what's been counted since the reader's mark, if anything has.
    ///   - total: the post's messages, which a count can't exceed.
    public static func unreadWords(count: Int?, total: Int) -> String {
        guard let count, count > 0 else { return "1+" }
        let shown = min(count, total > 0 ? total : count)
        return shown >= unreadCap ? "\(unreadCap)+" : String(shown)
    }

    /// Where a search's words fall in a post's title: Discord's `th`, each word on
    /// its own, whatever the case.
    public static func matches(of phrase: String, in title: String) -> [Range<String.Index>] {
        let words = phrase.split(whereSeparator: \.isWhitespace).map(String.init)
        var found: [Range<String.Index>] = []
        for word in words {
            var searchFrom = title.startIndex
            while searchFrom < title.endIndex,
                  let hit = title.range(
                      of: word,
                      options: [.caseInsensitive, .diacriticInsensitive],
                      range: searchFrom..<title.endIndex
                  )
            {
                found.append(hit)
                searchFrom = hit.upperBound
            }
        }
        return found.sorted { $0.lowerBound < $1.lowerBound }
    }
}
