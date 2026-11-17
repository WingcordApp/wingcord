import Foundation

/// The build Discord's web client is on today, read off the page that loads it.
///
/// **Why a client reads this at all**: Discord gates newly shipped routes on
/// the `client_build_number` in `X-Super-Properties`, and a number left behind
/// fails on exactly the newest feature — Scheduled Messages answered 401 at
/// 587,597, Nitro Emoji Packs 404 at 617,136. A number that keeps itself
/// current never drifts into that.
///
/// discord.com/app is the page every browser loads; its `GLOBAL_ENV` carries
/// `"BUILD_NUMBER":"675174"` in the clear. One small GET, no credentials.
public enum DiscordWebBuild {

    /// The page the number is read from.
    public static let pageURL = URL(string: "https://discord.com/app")!

    /// The build number in a copy of the page, or nil when the page has
    /// changed shape. Six to eight digits, as Discord's have been for years.
    public static func parse(_ html: String) -> Int? {
        let pattern = #""BUILD_NUMBER"\s*:\s*"?(\d{6,8})"?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html)
        else { return nil }
        return Int(html[range])
    }

    /// Fetches the page and reads the number. Nil on any failure: the caller
    /// keeps what it had.
    public static func fetch(userAgent: String, session: URLSession = .shared) async -> Int? {
        var request = URLRequest(url: pageURL, timeoutInterval: 15)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let html = String(data: data, encoding: .utf8)
        else { return nil }
        return parse(html)
    }
}
