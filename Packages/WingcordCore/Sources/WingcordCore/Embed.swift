import Foundation

/// A rich embed.
///
/// Every field is optional because Discord's is: a link preview, a bot's status
/// card and an image-only unfurl are the same object with different subsets
/// populated. The renderer branches on what is present, never on `kind` — the
/// kind string is advisory and Discord has shipped `rich` embeds that are
/// image-only and `image` embeds that carry a description.
public struct Embed: Hashable, Sendable, Codable {
    public struct Media: Hashable, Sendable, Codable {
        public var url: String
        public var proxyURL: String?
        public var width: Int?
        public var height: Int?
        /// Discord's `IS_ANIMATED` mark on the picture. See
        /// `CDN.playsAsAnimated`.
        public var isMarkedAnimated: Bool
        /// Discord's blurred stand-in — see `MediaPlaceholder`.
        public var placeholder: String?
        /// A Components V2 gallery item's own facts: its `content_type` said
        /// video, it was sent as a spoiler, and what it is of.
        public var isVideo = false
        public var isSpoiler = false
        public var altText: String?

        public init(
            url: String,
            proxyURL: String? = nil,
            width: Int? = nil,
            height: Int? = nil,
            isMarkedAnimated: Bool = false,
            placeholder: String? = nil
        ) {
            self.url = url
            self.proxyURL = proxyURL
            self.width = width
            self.height = height
            self.isMarkedAnimated = isMarkedAnimated
            self.placeholder = placeholder
        }

        /// Whether Discord's client plays it as moving. See
        /// `CDN.playsAsAnimated`.
        public var playsAsAnimated: Bool {
            CDN.playsAsAnimated(url, isMarkedAnimated: isMarkedAnimated)
        }

        public var aspectRatio: Double? {
            guard let width, let height, width > 0, height > 0 else { return nil }
            return Double(width) / Double(height)
        }

        /// Its pixels, where the payload said.
        public var pixelSize: CGSize? {
            guard let width, let height, width > 0, height > 0 else { return nil }
            return CGSize(width: width, height: height)
        }
    }

    public struct Author: Hashable, Sendable, Codable {
        public var name: String
        public var url: String?
        public var iconURL: String?

        public init(name: String, url: String? = nil, iconURL: String? = nil) {
            self.name = name
            self.url = url
            self.iconURL = iconURL
        }
    }

    public struct Footer: Hashable, Sendable, Codable {
        public var text: String
        public var iconURL: String?

        public init(text: String, iconURL: String? = nil) {
            self.text = text
            self.iconURL = iconURL
        }
    }

    public struct Field: Hashable, Sendable, Codable {
        public var name: String
        public var value: String
        public var isInline: Bool

        public init(name: String, value: String, isInline: Bool) {
            self.name = name
            self.value = value
            self.isInline = isInline
        }
    }

    public var title: String?
    public var kind: String?
    public var description: String?
    public var url: String?
    public var timestamp: Date?
    /// Discord's 24-bit accent for the embed's leading rule. Zero means unset.
    public var colorValue: UInt32?
    public var author: Author?
    public var footer: Footer?
    public var image: Media?
    public var thumbnail: Media?
    public var video: Media?
    public var fields: [Field]
    /// The site name, for a link unfurl.
    public var providerName: String?
    /// The body of an embed of type `components` — a Components V2 tree,
    /// which Discord draws in place of a card (`MessageAccessories.renderEmbeds`)
    /// and its unfurler sends for sites that describe themselves that way.
    public var components: [DisplayComponent]
    /// The pictures of the embeds after this one that share its link, which
    /// Discord draws as one card's gallery — see `mergingGalleries`.
    public var galleryImages: [Media] = []

    public init(
        title: String? = nil,
        kind: String? = nil,
        description: String? = nil,
        url: String? = nil,
        timestamp: Date? = nil,
        colorValue: UInt32? = nil,
        author: Author? = nil,
        footer: Footer? = nil,
        image: Media? = nil,
        thumbnail: Media? = nil,
        video: Media? = nil,
        fields: [Field] = [],
        providerName: String? = nil,
        components: [DisplayComponent] = []
    ) {
        self.title = title
        self.kind = kind
        self.description = description
        self.url = url
        self.timestamp = timestamp
        self.colorValue = colorValue
        self.author = author
        self.footer = footer
        self.image = image
        self.thumbnail = thumbnail
        self.video = video
        self.fields = fields
        self.providerName = providerName
        self.components = components
    }

    /// Folds the embeds that share a link into the first of them — Discord's
    /// `y` in module `659674`.
    ///
    /// **A post with four pictures unfurls as four embeds with one URL**, and
    /// Discord draws them as one card with a gallery: the first keeps its text
    /// and gains the others' pictures, and the rest go. An embed with no URL
    /// is kept as it is — there is nothing to match it on.
    public static func mergingGalleries(_ embeds: [Embed]) -> [Embed] {
        guard embeds.count > 1 else { return embeds }
        var merged: [Embed] = []
        var firstByURL: [String: Int] = [:]
        for embed in embeds {
            guard let url = embed.url else {
                merged.append(embed)
                continue
            }
            guard let index = firstByURL[url] else {
                firstByURL[url] = merged.count
                merged.append(embed)
                continue
            }
            if let image = embed.image { merged[index].galleryImages.append(image) }
        }
        return merged
    }

    /// The picture an embed that is *only* a picture is made of, or nil where
    /// the embed is a card.
    ///
    /// These render with no card, no rule and no padding, which is how Discord
    /// draws a pasted image link. Treating one as a card puts an empty bordered
    /// box around a photograph — and, worse, drops the photograph into the
    /// 80-point thumbnail well in the corner.
    ///
    /// **A `type: "image"` embed carries its picture in `thumbnail`, and `image`
    /// is absent entirely.** Captured, `threads.har`:
    ///
    /// ```json
    /// { "type": "image",
    ///   "url": "https://cdn.discordapp.com/emojis/1180624887707074641.webp?…",
    ///   "thumbnail": { "url": "…", "proxy_url": "…", "width": 48, "height": 36 } }
    /// ```
    ///
    /// Reading `image` alone is what made every pasted picture and every direct
    /// `.gif` link render as a short empty card with a tiny thumbnail beside it.
    ///
    /// **A `gifv` is bare even though it has a title.** Tenor's unfurl carries a
    /// title, a provider and a page URL, and Discord draws none of them — just
    /// the picture. So the type decides here, not the emptiness test: an embed
    /// that *is* a GIF is not a link preview that happens to have one.
    public var bareMedia: Media? {
        if kind == "gifv" {
            // **The thumbnail, not the video**, as the poster: the clip itself
            // plays over it — see `EmbedVideo.loop`.
            return thumbnail ?? image
        }
        // A video with a title, an author or a provider is a card — YouTube's
        // is — and one with none of them is a pasted clip, bare, below.
        guard title == nil, description == nil, author == nil, footer == nil, fields.isEmpty
        else { return nil }
        return image ?? thumbnail
    }

    /// Whether this embed draws as a bare picture rather than as a card.
    public var isBareImage: Bool { bareMedia != nil }
}
