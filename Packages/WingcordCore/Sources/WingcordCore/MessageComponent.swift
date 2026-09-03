import Foundation

/// A control an app attached to a message.
///
/// **Only what a reading client can honour is modelled.** Discord's component
/// tree has grown to a dozen types; this carries the two that decide whether a
/// bot's message makes sense at all — the row, and the button — plus a
/// placeholder for a menu, so a message built entirely out of one does not draw
/// as a gap.
///
/// **Two kinds are live.** A link button opens its URL. A button with a
/// `custom_id` posts an interaction — `POST /interactions` with `type: 3`,
/// captured in `slash help.har` — and the application answers by editing the
/// message underneath it. Everything else is drawn dimmed, which is the honest
/// answer: a control that looks pressable and does nothing is worse than one
/// that says it is not.
///
/// A select menu is still dimmed, and that is a decision rather than an
/// oversight. Its interaction carries `data.values` — the options chosen — and
/// no capture in this repository contains one. `INVARIANTS.md` §5.5.
public struct ActionRow: Hashable, Sendable, Codable {
    public var components: [MessageComponent]

    public init(components: [MessageComponent]) {
        self.components = components
    }
}

public struct MessageComponent: Hashable, Sendable, Identifiable, Codable {
    public enum Kind: Hashable, Sendable, Codable {
        /// Opens a URL.
        case link(String)
        /// Posts an interaction naming this `custom_id`. The application answers
        /// by editing the message the button is attached to.
        case action(customID: String)
        /// A select menu, drawn as its placeholder. Its interaction carries the
        /// options chosen, and that shape is not captured.
        case menu
        /// A button this client cannot honour — a link with no URL, or an action
        /// with no `custom_id`. Drawn as the inert control it is rather than
        /// dropped, because a bot's message is unreadable with a control missing
        /// from the middle of it.
        case inert
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

    /// What pressing it posts, or nil for anything that is not a live action
    /// button. Disabled is checked here for the same reason it is checked on a
    /// link: Discord marked the control unavailable, and this client does not
    /// get to disagree.
    public var customID: String? {
        guard case .action(let customID) = kind, !isDisabled else { return nil }
        return customID
    }

    /// Whether pressing it does anything in this client.
    public var isActionable: Bool { destination != nil || customID != nil }
}
