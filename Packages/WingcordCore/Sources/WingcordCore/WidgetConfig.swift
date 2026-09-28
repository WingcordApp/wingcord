import Foundation

/// How an application wants its widget drawn.
///
/// **The config is a template and the identity is the data.** Neither one alone
/// draws anything: the config says "the first stat's label is `Authority Level`
/// and its value is the identity field named `level`", and the identity says
/// `level = 60`. `ResolvedWidget` is what comes out of putting them together,
/// and it is the only thing a view sees.
///
/// Two routes answer with these and they are the same shape. `/widget-configs/
/// featured` answers for every application Discord has promoted — which is how
/// its own client already knows Arknights' labels without asking for them the
/// moment a profile opens — and `/applications/{id}/widget-configs` answers for
/// one application, which is the only way to reach a config somebody authored
/// for themselves.
public struct WidgetConfig: Hashable, Sendable, Identifiable {
    public var configID: String
    public var applicationID: ApplicationID
    /// What the *author* called it. Not what the widget's header shows — that is
    /// the application's own name, and the two differ: the captured widget is
    /// titled "THE widget" and headed "cool thing".
    public var displayName: String
    public var status: Status
    /// Keyed by `WidgetSurface.Kind.rawValue`, unknown kinds included.
    public var surfaces: [String: WidgetSurface]
    /// Assets an `application_asset` field can name, by their key.
    public var assets: [String: WidgetAsset]
    public var publishedAt: Date?
    public var updatedAt: Date?

    public var id: String { configID }

    public init(
        configID: String,
        applicationID: ApplicationID,
        displayName: String,
        status: Status = .published,
        surfaces: [String: WidgetSurface] = [:],
        assets: [String: WidgetAsset] = [:],
        publishedAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.configID = configID
        self.applicationID = applicationID
        self.displayName = displayName
        self.status = status
        self.surfaces = surfaces
        self.assets = assets
        self.publishedAt = publishedAt
        self.updatedAt = updatedAt
    }

    public enum Status: String, Hashable, Sendable {
        case published
        case draft
    }

    public func surface(_ kind: WidgetSurface.Kind) -> WidgetSurface? {
        surfaces[kind.rawValue]
    }

    /// Everything one surface draws, once the identity has been substituted in.
    ///
    /// Nil for a surface this config does not define — which is normal: a
    /// config that defines only `widget_bottom` is a stats block with no header,
    /// and drawing an empty header for it would be a client inventing chrome.
    public func resolve(
        _ kind: WidgetSurface.Kind,
        with profile: ApplicationProfile?,
        assetURL: (ApplicationID, String) -> URL?
    ) -> ResolvedSurface? {
        guard let surface = surface(kind) else { return nil }
        return surface.resolve(
            applicationID: applicationID,
            profile: profile,
            assets: assets,
            assetURL: assetURL
        )
    }
}

/// One of a config's surfaces.
public struct WidgetSurface: Hashable, Sendable {
    /// The layout key. Kept as a string: it selects between arrangements this
    /// client draws the same way, and a closed enum would reject one Discord
    /// adds rather than falling through to the arrangement that already works.
    public var layout: String
    /// Keyed by component name — `title`, `subtitle_1`, `hero_image`, `stat_1`.
    public var components: [String: WidgetComponent]

    public init(layout: String, components: [String: WidgetComponent]) {
        self.layout = layout
        self.components = components
    }

    public enum Kind: String, Hashable, Sendable, CaseIterable {
        case widgetTop = "widget_top"
        case widgetBottom = "widget_bottom"
        case addWidgetPreview = "add_widget_preview"
        case miniProfile = "mini_profile"
        case activityAccessory = "activity_accessory"
    }

    /// Whether the layout puts its picture behind the text rather than in a box
    /// beside it. `…_hero` against `…_contained`, which is the only difference
    /// between the two arrangements Discord ships for each surface.
    public var isHero: Bool { layout.hasSuffix("_hero") || layout.hasSuffix("_hero_stat") }

    func resolve(
        applicationID: ApplicationID,
        profile: ApplicationProfile?,
        assets: [String: WidgetAsset],
        assetURL: (ApplicationID, String) -> URL?
    ) -> ResolvedSurface {
        func field(_ component: String, _ field: String) -> WidgetField? {
            components[component]?.fields[field]
        }
        func text(_ component: String, _ name: String = "text") -> String? {
            field(component, name)?.resolveText(in: profile)
        }
        func image(_ component: String, _ name: String = "image") -> URL? {
            field(component, name)?.resolveImage(
                applicationID: applicationID,
                profile: profile,
                assets: assets,
                assetURL: assetURL
            )
        }

        // **Sorted by the number in the key, never by the dictionary's order.**
        // A JSON object has none, so reading `components` as it decodes puts
        // "aaa" before "uhm" about half the time — which is exactly what the
        // captured widget's three stats would do.
        let statKeys = components.keys
            .filter { $0.hasPrefix("stat_") }
            .sorted(by: Self.byTrailingNumber)
        let stats: [ResolvedStat] = statKeys.compactMap { key in
            let value = text(key, "value") ?? ""
            let label = text(key, "label") ?? ""
            // An empty slot is a slot the author left blank — the captured
            // config carries six and filled three — so it draws nothing rather
            // than a gap with a blank label under it.
            guard !value.isEmpty || !label.isEmpty else { return nil }
            return ResolvedStat(key: key, value: value, label: label, iconURL: image(key, "icon"))
        }

        // **The popout's one stat is `stat`, with no number** — Discord's
        // `mini_profile_*` layouts name it that, and a filter on `stat_` never
        // saw it. It reads "Label: text" when it has a label (module `779300`),
        // which is how Arknights' "Authority Level: 60" is written.
        let headline: ResolvedStat? = components["stat"].flatMap { _ in
            let value = text("stat")
            let label = text("stat", "label")
            guard value != nil || label != nil else { return nil }
            let shown = value ?? "\u{2013}"
            return ResolvedStat(
                key: "stat",
                value: label.map { "\($0): \(shown)" } ?? shown,
                label: "",
                iconURL: image("stat", "icon")
            )
        }

        let subtitleKeys = components.keys
            .filter { $0.hasPrefix("subtitle") }
            .sorted(by: Self.byTrailingNumber)

        // **`current` and `max`, not `value`** — the progress layout's own
        // field names (module `794248`). Reading `value` found nothing, and
        // the card fell back to printing the raw fraction as a stat.
        let progress: ResolvedProgress? = components["progress"].map { _ in
            ResolvedProgress(
                current: field("progress", "current")?.resolveNumber(in: profile),
                maximum: field("progress", "max")?.resolveNumber(in: profile),
                name: text("objective", "name"),
                detail: text("objective", "description"),
                imageURL: image("objective")
            )
        }

        let items: [ResolvedItem] = components.keys
            .filter { $0.hasPrefix("item_") }
            .sorted(by: Self.byTrailingNumber)
            .compactMap { key in
                let item = ResolvedItem(
                    key: key,
                    name: text(key, "name"),
                    detail: text(key, "description"),
                    imageURL: image(key)
                )
                return item.name == nil && item.detail == nil && item.imageURL == nil ? nil : item
            }

        return ResolvedSurface(
            layout: layout,
            isHero: isHero,
            title: text("title"),
            subtitles: subtitleKeys.compactMap { text($0) }.filter { !$0.isEmpty },
            heroImageURL: image("hero_image") ?? image("image") ?? image("icon"),
            containedImageURL: image("contained_image"),
            stats: stats,
            headline: headline,
            progress: progress,
            items: items
        )
    }

    /// `stat_2` before `stat_10`, which a plain string sort gets backwards.
    static func byTrailingNumber(_ lhs: String, _ rhs: String) -> Bool {
        func rank(_ key: String) -> (Int, String) {
            guard let underscore = key.lastIndex(of: "_"),
                  let number = Int(key[key.index(after: underscore)...])
            else { return (Int.max, key) }
            return (number, key)
        }
        let (leftNumber, leftKey) = rank(lhs)
        let (rightNumber, rightKey) = rank(rhs)
        return leftNumber == rightNumber ? leftKey < rightKey : leftNumber < rightNumber
    }
}

public struct WidgetComponent: Hashable, Sendable {
    /// Keyed by field name — `text`, `value`, `label`, `image`.
    public var fields: [String: WidgetField]

    public init(fields: [String: WidgetField]) {
        self.fields = fields
    }
}

/// One slot in a component, and where its content comes from.
public indirect enum WidgetField: Hashable, Sendable {
    case field(Value)
    /// A slot with a standby, used when the primary resolves to nothing.
    case fallback(Value, WidgetField)

    public struct Value: Hashable, Sendable {
        public var valueType: ValueType
        public var presentationType: PresentationType
        /// A literal, an identity field's name, or an asset's key — which of
        /// the three is `valueType`'s whole job to say.
        public var value: String

        public init(valueType: ValueType, presentationType: PresentationType, value: String) {
            self.valueType = valueType
            self.presentationType = presentationType
            self.value = value
        }
    }

    public enum ValueType: String, Hashable, Sendable {
        /// Names a field on the person's application profile.
        case data
        /// Is the string.
        case customString = "custom_string"
        /// Names one of the config's resolved assets.
        case applicationAsset = "application_asset"
        /// Names a string the application localised. Nothing in this client can
        /// resolve one, so it renders as nothing rather than as its key.
        case applicationLocalizedString = "application_localized_string"
        case unknown

        public init(rawValue: String) {
            switch rawValue {
            case "data": self = .data
            case "custom_string": self = .customString
            case "application_asset": self = .applicationAsset
            case "application_localized_string": self = .applicationLocalizedString
            default: self = .unknown
            }
        }

        public var rawValue: String {
            switch self {
            case .data: "data"
            case .customString: "custom_string"
            case .applicationAsset: "application_asset"
            case .applicationLocalizedString: "application_localized_string"
            case .unknown: "unknown"
            }
        }
    }

    public enum PresentationType: String, Hashable, Sendable {
        case text
        case number
        case image
        case duration
        case unknown

        public init(rawValue: String) {
            switch rawValue {
            case "text": self = .text
            case "number": self = .number
            case "image": self = .image
            case "duration": self = .duration
            default: self = .unknown
            }
        }

        public var rawValue: String {
            switch self {
            case .text: "text"
            case .number: "number"
            case .image: "image"
            case .duration: "duration"
            case .unknown: "unknown"
            }
        }
    }

    var primary: Value {
        switch self {
        case .field(let value), .fallback(let value, _): value
        }
    }

    var standby: WidgetField? {
        if case .fallback(_, let standby) = self { return standby }
        return nil
    }

    /// The text this slot prints, or nil when it has none to print.
    public func resolveText(in profile: ApplicationProfile?) -> String? {
        let value = primary
        let resolved: String?
        switch value.valueType {
        case .customString:
            resolved = value.value.isEmpty ? nil : value.value
        case .data:
            resolved = profile?.field(named: value.value)
                .map { $0.formatted(as: value.presentationType) }
        case .applicationAsset, .applicationLocalizedString, .unknown:
            resolved = nil
        }
        if let resolved, !resolved.isEmpty { return resolved }
        return standby?.resolveText(in: profile)
    }

    /// The number behind a progress component's `current` or `max`.
    public func resolveNumber(in profile: ApplicationProfile?) -> Double? {
        let value = primary
        switch value.valueType {
        case .customString: return Double(value.value)
        case .data:
            if case .number(let number)? = profile?.field(named: value.value) { return number }
            return nil
        case .applicationAsset, .applicationLocalizedString, .unknown: return nil
        }
    }

    /// Where this slot's picture is.
    public func resolveImage(
        applicationID: ApplicationID,
        profile: ApplicationProfile?,
        assets: [String: WidgetAsset],
        assetURL: (ApplicationID, String) -> URL?
    ) -> URL? {
        let value = primary
        let resolved: URL?
        switch value.valueType {
        case .applicationAsset:
            resolved = assets[value.value]
                .flatMap { assetURL(applicationID, $0.assetID) }
        case .data:
            if case .image(let url)? = profile?.field(named: value.value) {
                resolved = url
            } else {
                resolved = nil
            }
        // **`data` with a URL in it is not a thing, and `custom_string` with one
        // is.** The captured `add_widget_preview` carries
        // `{"value_type": "data", "value": "change this to an image"}` — an
        // author's placeholder, not an address. Anything that does not parse as
        // a URL resolves to nothing.
        case .customString:
            resolved = URL(string: value.value).flatMap { $0.scheme == nil ? nil : $0 }
        case .applicationLocalizedString, .unknown:
            resolved = nil
        }
        if let resolved { return resolved }
        return standby?.resolveImage(
            applicationID: applicationID,
            profile: profile,
            assets: assets,
            assetURL: assetURL
        )
    }
}

/// One picture the config registered, so a field can name it by key.
public struct WidgetAsset: Hashable, Sendable {
    public var key: String
    public var assetID: String
    public var width: Int?
    public var height: Int?
    public var isAnimated: Bool

    public init(
        key: String,
        assetID: String,
        width: Int? = nil,
        height: Int? = nil,
        isAnimated: Bool = false
    ) {
        self.key = key
        self.assetID = assetID
        self.width = width
        self.height = height
        self.isAnimated = isAnimated
    }
}

// MARK: - What a view draws

/// One surface, with every reference already resolved.
///
/// The view layer never sees a `WidgetField` — a template with a data reference
/// in it is not something a `body` should be walking, and resolving in the view
/// means the same substitution happens once per frame per stat.
public struct ResolvedSurface: Hashable, Sendable {
    public var layout: String
    public var isHero: Bool
    public var title: String?
    public var subtitles: [String]
    public var heroImageURL: URL?
    /// A picture drawn in a box beside the words rather than behind them — the
    /// `…_contained_*` layouts' `contained_image`.
    public var containedImageURL: URL?
    public var stats: [ResolvedStat]
    /// The one stat a popout card leads with — `mini_profile_*`'s `stat`.
    public var headline: ResolvedStat?
    /// `widget_bottom_progress`: one goal and how far along it is.
    public var progress: ResolvedProgress?
    /// `widget_bottom_collection`: up to four things, each a picture and two
    /// lines.
    public var items: [ResolvedItem]

    public init(
        layout: String,
        isHero: Bool,
        title: String? = nil,
        subtitles: [String] = [],
        heroImageURL: URL? = nil,
        containedImageURL: URL? = nil,
        stats: [ResolvedStat] = [],
        headline: ResolvedStat? = nil,
        progress: ResolvedProgress? = nil,
        items: [ResolvedItem] = []
    ) {
        self.layout = layout
        self.isHero = isHero
        self.title = title
        self.subtitles = subtitles
        self.heroImageURL = heroImageURL
        self.containedImageURL = containedImageURL
        self.stats = stats
        self.headline = headline
        self.progress = progress
        self.items = items
    }

    public var isEmpty: Bool {
        title == nil && subtitles.isEmpty && heroImageURL == nil && containedImageURL == nil
            && stats.isEmpty && headline == nil && progress == nil && items.isEmpty
    }
}

/// `widget_bottom_progress`, resolved (module `794248`): the goal's badge, its
/// name and line, and the bar.
public struct ResolvedProgress: Hashable, Sendable {
    public var name: String?
    public var detail: String?
    public var imageURL: URL?
    /// How full the bar is, in whole percent, 0 to 100.
    public var percent: Int
    /// What the bar's end says: "69%", or "5/10" when the template names a
    /// maximum. Nil while the number itself is missing.
    public var caption: String?

    public init(
        name: String? = nil,
        detail: String? = nil,
        imageURL: URL? = nil,
        percent: Int,
        caption: String?
    ) {
        self.name = name
        self.detail = detail
        self.imageURL = imageURL
        self.percent = percent
        self.caption = caption
    }

    /// Discord's arithmetic (module `779300`): `current` alone is a fraction
    /// of one; with `max` it is a count out of that. Rounded to whole
    /// percent, clamped, and an empty or zero maximum is an empty bar.
    public init(
        current: Double?,
        maximum: Double?,
        name: String? = nil,
        detail: String? = nil,
        imageURL: URL? = nil
    ) {
        func percent(_ fraction: Double) -> Int {
            fraction.isNaN ? 0 : Int(min(max((fraction * 100).rounded(), 0), 100))
        }
        let filled: Int
        let caption: String?
        switch (current, maximum) {
        case (nil, _):
            filled = 0
            caption = nil
        case (let current?, nil):
            filled = percent(current)
            caption = "\(filled)%"
        case (let current?, let maximum?):
            filled = maximum == 0 ? 0 : percent(current / maximum)
            caption = "\(Self.plain(current))/\(Self.plain(maximum))"
        }
        self.init(name: name, detail: detail, imageURL: imageURL, percent: filled, caption: caption)
    }

    /// A number the way Discord's template string prints it: `5`, not `5.0`.
    static func plain(_ value: Double) -> String {
        if value.rounded() == value, abs(value) < 1e15 { return String(Int64(value)) }
        return String(value)
    }

    public var isEmpty: Bool { name == nil && detail == nil && imageURL == nil && caption == nil }
}

/// One of `widget_bottom_collection`'s four things.
public struct ResolvedItem: Hashable, Sendable, Identifiable {
    /// The component key — `item_1` to `item_4`.
    public var key: String
    public var name: String?
    public var detail: String?
    public var imageURL: URL?

    public var id: String { key }

    public init(key: String, name: String? = nil, detail: String? = nil, imageURL: URL? = nil) {
        self.key = key
        self.name = name
        self.detail = detail
        self.imageURL = imageURL
    }
}

public struct ResolvedStat: Hashable, Sendable, Identifiable {
    /// The component key it came from, which is a stable identity across a
    /// refresh in a way the value is not.
    public var key: String
    public var value: String
    public var label: String
    /// The picture after the number — Gramophone's waveform after its
    /// scrobbles. Discord draws every stat's `icon` field one line tall.
    public var iconURL: URL?

    public var id: String { key }

    public init(key: String, value: String, label: String, iconURL: URL? = nil) {
        self.key = key
        self.value = value
        self.label = label
        self.iconURL = iconURL
    }
}

// MARK: - The application behind a widget

/// The application an `application` widget names.
///
/// **Not the same id as the game it is about.** Arknights' widget names
/// application `1496037472226906183`, whose `linked_games` names game
/// `1461154307171811401` — a different application entirely, and the one
/// `/games` answers for. Nothing on the widget carries that second id, so
/// "View Game Profile" on a widget cannot work without this hop, and a client
/// that assumed the two were one would open a game profile for an application
/// that has no game data at all.
public struct WidgetApplication: Hashable, Sendable, Identifiable {
    public var id: ApplicationID
    public var name: String
    public var iconHash: String?
    public var isVerified: Bool
    /// Where the game sends somebody to link their account — Arknights'
    /// `endfield.gryphline.com/special/discord-binding`. Its presence is what
    /// makes the game profile offer to link rather than to buy: a game with an
    /// entrypoint shows the Link Account card, and one without shows its store
    /// button.
    public var connectionEntrypointURL: URL?
    /// The games this application publishes stats for.
    public var linkedGameIDs: [ApplicationID]

    public init(
        id: ApplicationID,
        name: String,
        iconHash: String? = nil,
        isVerified: Bool = false,
        connectionEntrypointURL: URL? = nil,
        linkedGameIDs: [ApplicationID] = []
    ) {
        self.id = id
        self.name = name
        self.iconHash = iconHash
        self.isVerified = isVerified
        self.connectionEntrypointURL = connectionEntrypointURL
        self.linkedGameIDs = linkedGameIDs
    }

    /// The game a widget for this application is about, when it names one.
    public var primaryGameID: ApplicationID? { linkedGameIDs.first }
}
