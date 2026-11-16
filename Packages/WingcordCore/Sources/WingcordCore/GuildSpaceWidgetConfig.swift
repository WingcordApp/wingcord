import Foundation

/// A widget's settings. Only Image + Text has any; every other kind's config
/// is its kind alone.
public struct GuildSpaceWidgetConfig: Hashable, Sendable {
    public var kind: GuildSpaceWidgetKind
    public var title: String?
    public var text: String?
    /// The saved picture, on the CDN under `/guild-space/…/image-text-widget/`.
    public var imageHash: String?
    /// A picture chosen in this edit and not yet saved.
    public var imageChange: ImageChange = .unchanged
    /// The config exactly as Discord sent it, for a kind this client doesn't
    /// edit: a save sends it back byte for byte rather than a reduced copy
    /// that could drop a setting made in Discord's own client.
    public var rawJSON: Data?

    /// **Three states, because a save has three things to say**: nothing
    /// (Discord keeps the picture), a new one (a data URL, as Discord's own
    /// file input sends), or none at all.
    public enum ImageChange: Hashable, Sendable {
        case unchanged
        case replaced(dataURL: String)
        case removed
    }

    public init(
        kind: GuildSpaceWidgetKind,
        title: String? = nil,
        text: String? = nil,
        imageHash: String? = nil
    ) {
        self.kind = kind
        self.title = title
        self.text = text
        self.imageHash = imageHash
    }

    /// Whether an Image + Text widget has anything to show: Discord's save
    /// refuses one with neither words nor a picture.
    public var hasContent: Bool {
        let hasText = !(text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasImage = switch imageChange {
        case .replaced: true
        case .removed: false
        case .unchanged: imageHash != nil
        }
        return hasText || hasImage
    }
}
