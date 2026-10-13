import Foundation

/// A signed link to an uploaded file, and when it stops working.
///
/// **Discord signs every attachment link and the signature expires** — `ex`
/// is the expiry in hex seconds, `is` when it was issued, `hm` the signature —
/// about a day after the message was fetched. A transcript that stays open,
/// or a message loaded yesterday, carries links the CDN now answers with 404:
/// the picture in the row is a decode cached long ago, and the viewer's larger
/// rendition is a fresh fetch that fails ("Couldn't load", Alex's image 41).
///
/// Discord's own rule (module `679164`): a link is due for refreshing when its
/// `ex` is missing, past, or less than an hour away, and the refresh is `POST
/// /attachments/refresh-urls`. Both hosts carry the same three parameters for
/// one file, so a signature refreshed for the CDN link is good for the
/// media proxy's renditions of it too.
public enum AttachmentLink {

    /// Discord's margin: a link with less than an hour left is refreshed now.
    public static let margin: TimeInterval = 60 * 60

    private static let hosts: Set<String> = ["cdn.discordapp.com", "media.discordapp.net"]
    private static let paths = ["/attachments/", "/ephemeral-attachments/"]
    private static let signature = ["ex", "is", "hm"]

    /// Whether this is a signed upload on Discord's CDN or its media proxy.
    public static func isSigned(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), hosts.contains(host) else { return false }
        return paths.contains { url.path.hasPrefix($0) }
    }

    /// Whether the link is due for refreshing — Discord's `f`.
    public static func needsRefresh(_ url: URL, now: Date = .now) -> Bool {
        guard isSigned(url) else { return false }
        guard let expiry = expiry(of: url) else { return true }
        return expiry <= now.addingTimeInterval(margin)
    }

    /// When the signature runs out, or nil where the link carries none.
    public static func expiry(of url: URL) -> Date? {
        guard let value = query(of: url)?.first(where: { $0.name == "ex" })?.value,
              let seconds = UInt64(value, radix: 16)
        else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    /// The file's own address with nothing but its signature — what the
    /// refresh route is asked about, whichever host and rendition it was.
    public static func canonical(_ url: URL) -> URL? {
        guard isSigned(url), var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        components.host = "cdn.discordapp.com"
        components.queryItems = (components.queryItems ?? []).filter { signature.contains($0.name) }
        if components.queryItems?.isEmpty == true { components.queryItems = nil }
        return components.url
    }

    /// `url` — any host, any rendition — carrying `refreshed`'s signature in
    /// place of its own, with everything else (a width, a format) kept.
    public static func resigned(_ url: URL, with refreshed: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        let fresh = (query(of: refreshed) ?? []).filter { signature.contains($0.name) }
        var items = (components.queryItems ?? []).filter { !signature.contains($0.name) }
        items.insert(contentsOf: fresh, at: 0)
        components.queryItems = items.isEmpty ? nil : items
        return components.url ?? url
    }

    private static func query(of url: URL) -> [URLQueryItem]? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
    }
}
