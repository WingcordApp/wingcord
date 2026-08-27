import Foundation

/// A control an app attached to a message.
///
/// **Only what a reading client can honour is modelled.** Discord's component
/// tree has grown to a dozen types; this carries the two that decide whether a
/// bot's message makes sense at all — the row, and the button — plus a
/// placeholder for a menu, so a message built entirely out of one does not draw
/// as a gap.
///
/// A link button is the one kind this client can actually *do*: its destination
/// is a URL and pressing it opens that URL. Everything else needs an interaction
/// round trip, which this client does not make — so those are drawn and
/// disabled, which is the honest answer. A control that looks live and does
/// nothing is worse than one that says it cannot be pressed.
public struct ActionRow: Hashable, Sendable, Codable {
    public var components: [MessageComponent]

    public init(components: [MessageComponent]) {
        self.components = components
    }
}

public struct MessageComponent: Hashable, Sendable, Identifiable, Codable {
    public enum Kind: Hashable, Sendable, Codable {
        /// Opens a URL. The only kind this client can honour.
        case link(String)
        /// Needs an interaction round trip. Drawn, disabled.
        case action
        /// A select menu, drawn as its placeholder.
        case menu
    }

    public enum Style: Int, Hashable, Sendable, Codable {
        case primary = 1
        case secondary = 2
        case success = 3
        case danger = 4
        case link = 5

        public init(rawValue: Int) {
            self = switch rawValue {
            case 1: .primary
            case 3: .success
            case 4: .danger
            case 5: .link
            default: .secondary
            }
        }
    }

    /// Stable within one message: Discord's `custom_id`, the URL, or the label.
    public var id: String
    public var label: String
    public var kind: Kind
    public var style: Style
    public var isDisabled: Bool
    /// The emoji on the button's leading edge, where it has one.
    public var emoji: EmojiRef?

    public init(
        id: String,
        label: String,
        kind: Kind,
        style: Style = .secondary,
        isDisabled: Bool = false,
        emoji: EmojiRef? = nil
    ) {
        self.id = id
        self.label = label
        self.kind = kind
        self.style = style
        self.isDisabled = isDisabled
        self.emoji = emoji
    }

    /// Where pressing it goes, or nil for anything this client cannot honour.
    ///
    /// A disabled link button has no destination *for this client* even though
    /// it carries a URL: honouring it would make a control Discord marked
    /// unavailable work here and nowhere else.
    public var destination: String? {
        guard case .link(let url) = kind, !isDisabled else { return nil }
        return url
    }

    /// Whether pressing it does anything in this client.
    public var isActionable: Bool { destination != nil }
}
