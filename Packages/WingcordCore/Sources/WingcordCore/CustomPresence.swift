import Foundation

/// A Rich Presence the reader made — Vencord's CustomRPC (`index.tsx`,
/// `RpcSettings.tsx`), as one card of the builder in the full profile's
/// Activity tab (DESIGN-NOTES §11).
///
/// **Everything is kept as typed**, links and numbers included, so a card can
/// hold a half-written line and say what is wrong with it; the activity is
/// built only from what passes Vencord's rules (`problem(_:)`).
public struct CustomPresence: Codable, Hashable, Sendable, Identifiable {
    /// The activity types Vencord offers, numbered as the wire numbers them.
    public enum Kind: Int, Codable, CaseIterable, Hashable, Sendable {
        case playing = 0
        case streaming = 1
        case listening = 2
        case watching = 3
        case competing = 5

        /// Vencord's labels.
        public var title: String {
            switch self {
            case .playing: "Playing"
            case .streaming: "Streaming"
            case .listening: "Listening"
            case .watching: "Watching"
            case .competing: "Competing"
            }
        }
    }

    /// Vencord's Timestamp Mode.
    public enum Timer: Codable, Hashable, Sendable {
        case none
        /// "Since discord open": from when this presence was turned on.
        case sinceOn
        /// "Same as your current time (not reset after 24h)": from midnight.
        case localTime
        case custom(start: Date?, end: Date?)

        /// Vencord's labels, in its order.
        public var title: String {
            switch self {
            case .none: "None"
            case .sinceOn: "Since discord open"
            case .localTime: "Same as your current time (not reset after 24h)"
            case .custom: "Custom"
            }
        }
    }

    /// One picture: a link or the application's own asset key, what hovering
    /// it says, and where a click on it goes.
    public struct Art: Codable, Hashable, Sendable {
        public var image = ""
        public var text = ""
        public var link = ""

        public init(image: String = "", text: String = "", link: String = "") {
            self.image = image
            self.text = text
            self.link = link
        }

        public var isEmpty: Bool { image.isEmpty }
    }

    public struct Button: Codable, Hashable, Sendable {
        public var label = ""
        public var link = ""

        public init(label: String = "", link: String = "") {
            self.label = label
            self.link = link
        }
    }

    public var id: UUID
    public var applicationID = ""
    /// Vencord's Application Name — the activity's `name`, and the one thing
    /// a presence must have.
    public var name = ""
    public var kind: Kind = .playing
    public var details = ""
    public var detailsLink = ""
    public var state = ""
    public var stateLink = ""
    public var streamLink = ""
    public var timer: Timer = .none
    public var largeArt = Art()
    public var smallArt = Art()
    /// Always two slots, as Vencord's two pairs of fields.
    public var buttons = [Button(), Button()]
    public var partySize = ""
    public var partyMax = ""

    public init(id: UUID = UUID()) {
        self.id = id
    }

    // MARK: Vencord's rules

    public enum Field: Hashable, Sendable {
        case applicationID, name, details, detailsLink, state, stateLink, streamLink
        case largeImage, largeText, largeLink, smallImage, smallText, smallLink
        case buttonLabel(Int), buttonLink(Int)
        case partySize, partyMax
    }

    /// What is wrong with one field, in Vencord's words — nil when nothing is.
    public func problem(_ field: Field) -> String? {
        switch field {
        case .applicationID:
            return applicationID.isEmpty || applicationID.wholeMatch(of: /\d{16,21}/) != nil
                ? nil : "Must be a valid Discord ID."
        case .name:
            if name.isEmpty { return "This field is required." }
            return Self.longer(name, than: 128)
        case .details: return Self.longer(details, than: 128)
        case .state: return Self.longer(state, than: 128)
        case .largeText: return Self.longer(largeArt.text, than: 128)
        case .smallText: return Self.longer(smallArt.text, than: 128)
        case .detailsLink: return Self.link(detailsLink)
        case .stateLink: return Self.link(stateLink)
        case .largeLink: return Self.link(largeArt.link)
        case .smallLink: return Self.link(smallArt.link)
        case .streamLink:
            guard kind == .streaming else { return nil }
            if streamLink.firstMatch(of: /https?:\/\/(www\.)?(twitch\.tv|youtube\.com)\/\w+/) == nil {
                return "Streaming link must be a valid URL."
            }
            return streamLink.count > 512 ? "Streaming link must be not longer than 512 characters." : nil
        case .largeImage: return Self.image(largeArt.image)
        case .smallImage: return Self.image(smallArt.image)
        case .buttonLabel(let index):
            return buttons.indices.contains(index) ? Self.longer(buttons[index].label, than: 31) : nil
        case .buttonLink(let index):
            return buttons.indices.contains(index) ? Self.link(buttons[index].link) : nil
        case .partySize: return Self.number(partySize)
        case .partyMax: return Self.number(partyMax)
        }
    }

    private static func longer(_ text: String, than limit: Int) -> String? {
        text.count > limit ? "Must be not longer than \(limit) characters." : nil
    }

    private static func link(_ text: String) -> String? {
        text.isEmpty || text.prefixMatch(of: /https?:\/\/.+/) != nil ? nil : "Must be a valid URL."
    }

    private static func number(_ text: String) -> String? {
        guard !text.isEmpty else { return nil }
        guard let value = Int(text) else { return "Must be a number." }
        return value < 0 ? "Must be a positive number." : nil
    }

    private static func image(_ text: String) -> String? {
        if text.firstMatch(of: /https?:\/\/(cdn|media)\.discordapp\.(com|net)\//) != nil {
            return "Don't use a Discord link. Use an Imgur image link instead."
        }
        if text.firstMatch(of: /https?:\/\/imgur\.com\//) != nil {
            return "Imgur link must be a direct link to the image (e.g. https://i.imgur.com/...). Right click the image and click 'Copy image address'"
        }
        if text.firstMatch(of: /https?:\/\/tenor\.com\//) != nil {
            return "Tenor link must be a direct link to the image (e.g. https://media.tenor.com/...). Right click the GIF and click 'Copy image address'"
        }
        return nil
    }

    /// Every field Vencord checks.
    public static let checkedFields: [Field] = [
        .applicationID, .name, .details, .detailsLink, .state, .stateLink, .streamLink,
        .largeImage, .largeText, .largeLink, .smallImage, .smallText, .smallLink,
        .buttonLabel(0), .buttonLink(0), .buttonLabel(1), .buttonLink(1), .partySize, .partyMax,
    ]

    /// Whether it can go out: a name, and nothing wrong anywhere.
    public var isPublishable: Bool {
        Self.checkedFields.allSatisfy { problem($0) == nil }
    }

    /// Whether its pictures can be shown: they go through the application,
    /// so without a valid ID there are none.
    public var carriesArt: Bool {
        !applicationID.isEmpty && problem(.applicationID) == nil
    }

    // MARK: The activity

    /// Vencord's `createActivity`.
    ///
    /// - Parameters:
    ///   - assets: each picture's id as the application resolved it, by the
    ///     link or key typed — `mp:` for a link. A picture not in it is left
    ///     out.
    ///   - turnedOnAt: when this presence was turned on, for "Since discord
    ///     open".
    public func activity(
        assets: [String: String],
        turnedOnAt: Date,
        now: Date,
        calendar: Calendar = .current
    ) -> RichPresenceActivity? {
        guard isPublishable else { return nil }
        var activity = RichPresenceActivity(
            type: kind.rawValue,
            name: name,
            details: details.nilIfEmpty,
            state: state.nilIfEmpty,
            applicationID: ApplicationID(rawValue: UInt64(applicationID) ?? 0),
            flags: Self.instanceFlag
        )
        activity.detailsURL = URL(string: detailsLink)
        activity.stateURL = URL(string: stateLink)
        if kind == .streaming { activity.url = URL(string: streamLink) }
        activity.timestamps = timestamps(turnedOnAt: turnedOnAt, now: now, calendar: calendar)

        let large = carriesArt ? largeArt.image.nilIfEmpty.flatMap { assets[$0] } : nil
        let small = carriesArt ? smallArt.image.nilIfEmpty.flatMap { assets[$0] } : nil
        if large != nil || small != nil {
            activity.assets = RichPresenceActivity.Assets(
                largeImage: large,
                largeText: large == nil ? nil : largeArt.text.nilIfEmpty,
                largeURL: large == nil ? nil : URL(string: largeArt.link),
                smallImage: small,
                smallText: small == nil ? nil : smallArt.text.nilIfEmpty,
                smallURL: small == nil ? nil : URL(string: smallArt.link)
            )
        }

        // A label with no link would put the two lists out of step, and the
        // link is what a button is.
        let sent = buttons.filter { !$0.label.isEmpty && !$0.link.isEmpty }
        activity.buttons = sent.map(\.label)
        activity.buttonURLs = sent.compactMap { URL(string: $0.link) }

        if kind == .playing, let size = Int(partySize), let maximum = Int(partyMax), size > 0, maximum > 0 {
            activity.party = RichPresenceActivity.Party(size: [size, maximum])
        }
        return activity
    }

    /// Discord's `INSTANCE` activity flag, which Vencord sets.
    public static let instanceFlag = 1 << 0

    private func timestamps(turnedOnAt: Date, now: Date, calendar: Calendar) -> RichPresenceActivity.Timestamps? {
        func ms(_ date: Date) -> Int { Int(date.timeIntervalSince1970 * 1000) }
        switch timer {
        case .none:
            return nil
        case .sinceOn:
            return .init(start: ms(turnedOnAt))
        case .localTime:
            return .init(start: ms(calendar.startOfDay(for: now)))
        case .custom(let start, let end):
            guard start != nil || end != nil else { return nil }
            return .init(start: start.map(ms), end: end.map(ms))
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
