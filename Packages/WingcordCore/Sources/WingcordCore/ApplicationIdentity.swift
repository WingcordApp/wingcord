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
                return Self.compact(number)
            }
        }
    }

    /// The locale a widget's numbers are written in: the reader's language,
    /// **without their region's override** — Discord writes "7.9K" for an
    /// English client wherever its reader lives, and `Locale.current` on a Mac
    /// set to English with a Moldovan region would write "7,9K".
    static let numberLocale = Locale(identifier: Locale.preferredLanguages.first ?? "en-US")

    /// Discord's widget number (module `108089`): the locale's compact form,
    /// **truncated, never rounded**. 102,312 is "102K", 7,948 is "7.9K" and
    /// 4,550 is "4.5K", not "4.6K"; below a thousand a number is itself.
    ///
    /// Discord keeps two significant figures under ten units and whole units
    /// above, then asks the locale to write the result — so the unit a locale
    /// counts in is read off the locale itself, as Discord reads it, rather
    /// than assumed to be a thousand.
    static func compact(_ value: Double, locale: Locale = numberLocale) -> String {
        let style = FloatingPointFormatStyle<Double>.number.notation(.compactName).locale(locale)
        guard value != 0, value.isFinite else { return value.formatted(style) }
        let magnitude = exponent(of: abs(value))
        var unit = 1.0
        if magnitude >= 0 {
            let power = pow(10, Double(magnitude))
            if let shown = leadingNumber(in: power.formatted(style), locale: locale), shown > 0 {
                unit = power / shown
            }
        }
        let scaled = value / unit
        let kept = max(min(exponent(of: abs(scaled)) - 1, 0), -15)
        let factor = pow(10, Double(-kept))
        let truncated = (scaled * factor).rounded(.down) / factor * unit
        return (truncated.isFinite ? truncated : value).formatted(style)
    }

    /// The power of ten at or below `value`, corrected for `log10`'s rounding
    /// at the boundaries — Discord's own loop.
    private static func exponent(of value: Double) -> Int {
        guard value > 0 else { return 0 }
        var exponent = Int(log10(value).rounded(.down))
        while pow(10, Double(exponent)) > value { exponent -= 1 }
        while pow(10, Double(exponent + 1)) <= value { exponent += 1 }
        return exponent
    }

    /// The number a compact string shows — "100" out of "100K", "1" out of "1万".
    private static func leadingNumber(in text: String, locale: Locale) -> Double? {
        let decimal = locale.decimalSeparator ?? "."
        var digits = ""
        for character in text {
            if let digit = character.wholeNumberValue {
                digits.append(String(digit))
            } else if String(character) == decimal {
                digits.append(".")
            }
        }
        return Double(digits)
    }

    /// Playtime, which is the one documented field sent in hours.
    static func duration(hours: Double) -> String {
        if hours < 1 {
            let minutes = Int((hours * 60).rounded())
            return "\(minutes) min"
        }
        return "\(Int64(min(hours, 1e15).rounded(.down)).formatted(.number)) hrs"
    }
}
