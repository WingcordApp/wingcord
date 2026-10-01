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
/// **A string select is live too**: its options are all in the message, and
/// what choosing sends is read out of Discord's own interaction builder — see
/// `SelectMenu`. The other selects pick from a server's members, roles or
/// channels, which needs a search this client has no picker for yet, so they
/// are drawn dimmed. `INVARIANTS.md` §5.5.
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
        /// A select menu, drawn as its placeholder or its chosen options.
        case select(SelectMenu)
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

    /// The select menu it is, when it is one this client can answer — see
    /// `SelectMenu.isAnswerable` — and Discord has not marked it unavailable.
    public var select: SelectMenu? {
        guard case .select(let menu) = kind, !isDisabled, menu.isAnswerable else { return nil }
        return menu
    }

    /// Whether it is drawn as a select menu at all, live or not.
    public var isSelectMenu: Bool {
        if case .select = kind { return true }
        return false
    }

    /// Whether pressing it does anything in this client.
    public var isActionable: Bool { destination != nil || customID != nil || select != nil }
}

/// A select menu on a message — Discord's string select (type 3) and its four
/// pickers (5 users, 6 roles, 7 users and roles, 8 channels).
///
/// **What choosing sends is Discord's own**: its interaction builder spreads the
/// select's state into `data` — `{component_type: 3, custom_id, type: 3,
/// values: […]}` — beside the message fields a button press carries. Read out
/// of the client (web `d4c7976eccf337f1`), not guessed.
public struct SelectMenu: Hashable, Sendable, Codable {
    public var customID: String
    /// The component type: 3 for a string select.
    public var type: Int
    public var placeholder: String?
    public var options: [Option]
    public var minValues: Int
    public var maxValues: Int

    public struct Option: Hashable, Sendable, Codable, Identifiable {
        public var label: String
        /// What is sent. The application's own string; never shown.
        public var value: String
        public var description: String?
        public var emoji: EmojiRef?
        /// Chosen already, as the message was sent.
        public var isDefault: Bool

        public var id: String { value }

        public init(label: String, value: String, description: String? = nil, emoji: EmojiRef? = nil, isDefault: Bool = false) {
            self.label = label
            self.value = value
            self.description = description
            self.emoji = emoji
            self.isDefault = isDefault
        }
    }

    public init(
        customID: String,
        type: Int = SelectMenu.stringType,
        placeholder: String? = nil,
        options: [Option] = [],
        minValues: Int = 1,
        maxValues: Int = 1
    ) {
        self.customID = customID
        self.type = type
        self.placeholder = placeholder
        self.options = options
        self.minValues = minValues
        self.maxValues = maxValues
    }

    public static let stringType = 3

    /// A string select with something to choose: the kind this client can
    /// answer, because every option is in the message.
    public var isAnswerable: Bool { type == Self.stringType && !options.isEmpty && !customID.isEmpty }

    /// One choice is the whole answer, and Discord sends it the moment it is
    /// made. With more, it sends when the list closes.
    public var isSingle: Bool { maxValues <= 1 }

    /// The options chosen as the message was sent.
    public var defaultValues: Set<String> { Set(options.filter(\.isDefault).map(\.value)) }

    /// What the menu says while closed: its chosen options, or its placeholder
    /// — Discord's own "Make a selection" where it names none.
    public var summary: String {
        let chosen = options.filter(\.isDefault).map(\.label)
        return chosen.isEmpty ? (placeholder ?? "Make a selection") : chosen.joined(separator: ", ")
    }

    /// Whether a set of values is one the application will take: within the
    /// menu's own bounds.
    public func accepts(_ values: Set<String>) -> Bool {
        values.count >= minValues && values.count <= maxValues
    }
}
