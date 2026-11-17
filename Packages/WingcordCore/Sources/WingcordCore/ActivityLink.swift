import Foundation

/// A link that opens an activity — `https://discord.com/activities/{app}` with
/// the referrer and the app's own ids after it, what an app's Share Link and
/// Discord's own copy write. Discord draws it as the app's card with Play
/// (Alex, 2026-11-17, his Image 25).
public struct ActivityLink: Hashable, Sendable {
    public var applicationID: ApplicationID
    public var customID: String?
    public var referrerID: UserID?

    public init(applicationID: ApplicationID, customID: String? = nil, referrerID: UserID? = nil) {
        self.applicationID = applicationID
        self.customID = customID
        self.referrerID = referrerID
    }

    /// The activity links a message's text carries, in order and each app
    /// once, on Discord's own hosts only.
    public static func links(in content: String) -> [ActivityLink] {
        guard content.contains("/activities/") else { return [] }
        var links: [ActivityLink] = []
        for match in content.matches(of: pattern) {
            guard let id = UInt64(match.1) else { continue }
            let query = match.2.map(String.init) ?? ""
            let items = URLComponents(string: "https://x/\(query)")?.queryItems ?? []
            let link = ActivityLink(
                applicationID: ApplicationID(rawValue: id),
                customID: items.first { $0.name == "custom_id" }?.value,
                referrerID: items.first { $0.name == "referrer_id" }?.value.flatMap(UInt64.init).map(UserID.init(rawValue:))
            )
            guard !links.contains(where: { $0.applicationID == link.applicationID }) else { continue }
            links.append(link)
            if links.count == 5 { break }
        }
        return links
    }

    /// Whether a URL is one of these, for the unfurl it replaces.
    public static func parse(_ url: String) -> ActivityLink? {
        links(in: url).first
    }

    nonisolated(unsafe) private static let pattern =
        /(?i)(?:https?:\/\/)?(?:www\.|ptb\.|canary\.)?discord(?:app)?\.com\/activities\/([0-9]{15,21})(\?[^\s<>)\]"']*)?/
}
