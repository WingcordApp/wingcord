import Foundation

/// Somebody's account inside a game that is linked to Discord.
///
/// `GET /users/{id}/application-identities?with_profiles=true` answers with one
/// of these per linked application. It is the **data half** of an application
/// widget: the numbers, the in-game name and the character art. What those
/// numbers are *called* lives in the application's `WidgetConfig`, and neither
/// half draws anything alone.
public struct ApplicationIdentity: Hashable, Sendable, Identifiable {
    public var applicationID: ApplicationID
    /// The account's id inside the game. A string, not a snowflake — it is the
    /// provider's, and Wuthering Waves' is a nine-digit decimal.
    public var externalUserID: String
    public var profile: ApplicationProfile?

    public var id: ApplicationID { applicationID }

    public init(
        applicationID: ApplicationID,
        externalUserID: String,
        profile: ApplicationProfile? = nil
    ) {
        self.applicationID = applicationID
        self.externalUserID = externalUserID
        self.profile = profile
    }

    /// Whether this identity actually carries anything to draw.
    ///
    /// **A linked application with no data is the normal case for a widget
    /// somebody authored themselves.** The captured "cool thing" widget has an
    /// identity whose `provider_issued_user_id` is `"0"`, whose username is null
    /// and whose `dynamic` array is empty — the whole widget is custom strings
    /// in its config. So an empty identity is not a failed fetch and must not
    /// suppress the widget.
    public var isEmpty: Bool { profile?.isEmpty ?? true }
}

/// The person as the game knows them.
public struct ApplicationProfile: Hashable, Sendable {
    /// Their in-game name.
    public var username: String?
    /// Everything the game published about them, by field name.
    ///
    /// **One flat table over Discord's two.** The wire splits this into
    /// `primary` — a fixed set of documented keys — and `dynamic`, an array the
    /// application fills in freely; but a widget config's `data` fields name a
    /// key without saying which half it is in, and Wuthering Waves publishes
    /// `server_name` in `dynamic` while the documentation lists it under
    /// `primary`. Two tables would mean every lookup checking both and one of
    /// them eventually being forgotten.
    public var fields: [String: ApplicationProfileValue]
    /// The order `dynamic` arrived in. A widget with no config falls back to
    /// printing these, and the game chose their order.
    public var fieldOrder: [String]

    public init(
        username: String? = nil,
        fields: [String: ApplicationProfileValue] = [:],
        fieldOrder: [String] = []
    ) {
        self.username = username.flatMap { $0.isEmpty ? nil : $0 }
        self.fields = fields
        self.fieldOrder = fieldOrder
    }

    public var isEmpty: Bool { username == nil && fields.isEmpty }

    /// One field by the name a widget config would use for it.
    ///
    /// **`username` answers here too, and it is not in `fields`.** The wire
    /// keeps the in-game name at the top level of the profile object while a
    /// config's `data` field names it like any other key — so a lookup that
    /// only searched the map would leave every linked game's header blank while
    /// the name sat one property away.
    public func field(named name: String) -> ApplicationProfileValue? {
        if let value = fields[name] { return value }
        if name == "username", let username { return .text(username) }
        return nil
    }

    /// The character art the game features for them, when there is any.
    ///
    /// Named by the one documented primary key rather than guessed at: both
    /// captured linked games publish it as `featured_played_character_image`,
    /// and both point at a URL on the game's own CDN with a Discord proxy
    /// beside it.
    public var featuredCharacterImageURL: URL? {
        if case .image(let url)? = fields["featured_played_character_image"] { return url }
        return nil
    }

    /// What to draw when no widget config could be resolved.
    ///
    /// **A real fallback, and a visibly poorer one.** Discord's own labels are
    /// authored per application — `level` is titled "Authority Level" and
    /// `domain_1_level` is titled "Valley IV Regional Development Level", and
    /// nothing in the identity could produce either. What this gives instead is
    /// the field's own name in title case, which is right for `union_level` and
    /// approximately right for the rest. It exists so a linked game whose config
    /// has not arrived shows its numbers rather than an empty card.
    public var fallbackStats: [ResolvedStat] {
        fieldOrder.compactMap { name in
            guard let value = fields[name], name != "featured_played_character_image" else {
                return nil
            }
            return ResolvedStat(
                key: name,
                value: value.formatted(as: .text),
                label: Self.humanised(name)
            )
        }
    }

    static func humanised(_ name: String) -> String {
        name.split(separator: "_")
            .map { word -> String in
                // Acronyms the game writes lowercase read wrong title-cased.
                word.count <= 2 ? word.uppercased() : word.capitalized
            }
            .joined(separator: " ")
    }
}

/// One value on an application profile.
///
/// The wire's `type` is `1` text, `2` number, `3` image; the documented `primary`
/// object is untyped and its values are read from their JSON shape instead.
public enum ApplicationProfileValue: Hashable, Sendable {
    case text(String)
    case number(Double)
    case image(URL)

    /// The value as a widget slot would print it.
    public func formatted(as presentation: WidgetField.PresentationType) -> String {
        switch self {
        case .text(let text):
            return text
        case .image(let url):
            return url.absoluteString
        case .number(let number):
            switch presentation {
            case .duration:
                return Self.duration(hours: number)
            default:
                return Self.number(number)
            }
        }
    }

    /// **Integral values lose their decimal point.** Every number on the wire is
    /// a JSON float, so an authority level of sixty arrives as `60.0` and a
    /// client that printed it verbatim would put "60.0 Authority Level" on a
    /// card.
    static func number(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 {
            return Int64(value).formatted(.number)
        }
        return value.formatted(.number.precision(.fractionLength(0...2)))
    }

    /// Playtime, which is the one documented field sent in hours.
    static func duration(hours: Double) -> String {
        if hours < 1 {
            let minutes = Int((hours * 60).rounded())
            return "\(minutes) min"
        }
        return "\(number(hours.rounded(.down))) hrs"
    }
}
