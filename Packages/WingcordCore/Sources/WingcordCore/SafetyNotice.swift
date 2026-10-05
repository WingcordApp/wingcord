import Foundation

/// Discord's two safety cards in its system DM, read from the message's one
/// embed — `renderSafetyPolicyNotice` (`sh`) and
/// `renderSafetySystemNotification` (`sC`). Discord draws either only when it
/// is the message's sole embed, and never as an ordinary card.
public enum SafetyNotice: Hashable, Sendable {
    /// `safety_policy_notice`: "You broke Discord's community guidelines".
    case policy(classificationID: String, incident: Date)
    /// `safety_system_notification`: a header, a body and its links.
    case system(SafetySystemNotification)

    public static let embedKinds: Set<String> = ["safety_policy_notice", "safety_system_notification"]

    public init?(_ message: Message) {
        guard message.embeds.count == 1, let embed = message.embeds.first else { return nil }
        switch embed.kind {
        case "safety_policy_notice":
            // `find`: the first field of each name.
            func first(_ name: String) -> String? { embed.fields.first { $0.name == name }?.value }
            guard let classification = first("classification_id"),
                  let seconds = first("incident_time").flatMap(Double.init)
            else { return nil }
            self = .policy(classificationID: classification, incident: Date(timeIntervalSince1970: seconds))
        case "safety_system_notification":
            self = .system(SafetySystemNotification(embed))
        default:
            return nil
        }
    }

    /// "Today", "Yesterday", "3 days ago" — Discord's `eevFb6` over moment's
    /// whole days since.
    public static func daysAgo(since date: Date, now: Date = .now) -> String {
        let days = Int((now.timeIntervalSince(date) / 86_400).rounded(.towardZero))
        switch days {
        case 0: return "Today"
        case 1: return "Yesterday"
        default: return "\(days) days ago"
        }
    }
}

/// A safety system notification's fields (`393033.f4`). **The last field of a
/// name wins** — Discord reduces them into one object.
public struct SafetySystemNotification: Hashable, Sendable {
    public enum Icon: String, Hashable, Sendable {
        case `default`
        case danger
    }

    public enum Link: Hashable, Sendable {
        /// "See Details" — the violation, by its classification.
        case details(classificationID: String)
        /// "Learn More", to a page of Discord's.
        case learnMore(URL)
    }

    public var header: String
    public var body: String
    public var icon: Icon?
    /// The footer's colour: Discord's grey, its red, or none at all.
    public var theme: Icon?
    public var date: Date
    /// The links in the footer, in the order the notification lists them —
    /// each only where what it needs came with it.
    public var links: [Link]

    init(_ embed: Embed) {
        var fields: [String: String] = [:]
        for field in embed.fields { fields[field.name] = field.value }
        header = fields["header"] ?? ""
        body = fields["body"] ?? ""
        icon = fields["icon_type"].flatMap(Icon.init(rawValue:))
        theme = fields["theme"].flatMap(Icon.init(rawValue:))
        date = Date(timeIntervalSince1970: fields["timestamp"].flatMap(Double.init) ?? 0)
        let classification = fields["classification_id"]
        let learnMore = fields["learn_more_link"].flatMap(URL.init(string:))
        links = (fields["ctas"] ?? "").split(separator: ",").compactMap { cta in
            switch cta {
            case "policy_violation_detail": classification.map { Link.details(classificationID: $0) }
            case "learn_more_link": learnMore.map { Link.learnMore($0) }
            default: nil
            }
        }
    }
}
