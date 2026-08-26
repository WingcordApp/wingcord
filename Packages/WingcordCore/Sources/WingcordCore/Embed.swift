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

        public init(url: String, proxyURL: String? = nil, width: Int? = nil, height: Int? = nil) {
            self.url = url
            self.proxyURL = proxyURL
            self.width = width
            self.height = height
        }

        public var aspectRatio: Double? {
            guard let width, let height, width > 0, height > 0 else { return nil }
            return Double(width) / Double(height)
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
        providerName: String? = nil
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
    }

    /// An embed that is nothing but a picture.
    ///
    /// These render as a bare image with no card, no rule and no padding, which
    /// is how Discord draws a pasted image link. Treating one as a card puts an
    /// empty bordered box around a photograph.
    public var isBareImage: Bool {
        title == nil && description == nil && author == nil && footer == nil
            && fields.isEmpty && image != nil
    }
}
