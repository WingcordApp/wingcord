import AppKit
import Foundation
import WingcordCore

/// The URL an activity's frame is loaded at, and the parameters it carries.
///
/// **Recovered from a `Referer` header, not from documentation.** The frame's
/// own document load is not an entry in `activities123.har` — it is a
/// sub-frame navigation — but every request the activity made afterwards
/// carries the frame's full URL in `Referer`, query string included. That is
/// where all seventeen parameters below come from, spelling and all.
///
/// ```
/// https://{application_id}.discordsays.com/
///   ?instance_id=i-1544784239373983785-pc-1424759145021837325
///   &location_id=pc-1424759145021837325
///   &launch_id=1544784239373983785
///   &referrer_id=undefined&custom_id=undefined
///   &theme=dark&ui_density=default&message_display_compact=false
///   &font_scale=100&reduced_motion=false&high_contrast=false
///   &forced_colors=false&underline_links=false
///   &discord_proxy_ticket=faux-proxy-ticket
///   &channel_id=1424759145021837325
///   &frame_id=129328db-ecc8-4d24-a723-ca3adad262ed
///   &platform=desktop
/// ```
///
/// **The host is per-application.** `{id}.discordsays.com` — a separate origin
/// per app, which is what lets the frame be sandboxed from everything else and
/// why the page's own network goes through `/.proxy/…` on that same host.
enum ActivityFrame {

    /// Whether an activity can be framed at all.
    ///
    /// Checked live against three applications — Watch Together, Wordle and
    /// Farm Merge Valley — and none of them sends `X-Frame-Options` or a CSP
    /// `frame-ancestors` directive. The origin will frame anywhere, which is
    /// the whole reason a native client can host one.
    static let host = "discordsays.com"

    static func url(
        application: ApplicationID,
        instance: ActivityInstanceID,
        proxyTicket: String,
        channelID: ChannelID,
        isServerHubChannel: Bool = false,
        frameID: UUID = UUID()
    ) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "\(application.rawValue).\(host)"
        components.path = "/"
        components.queryItems = [
            URLQueryItem(name: "instance_id", value: instance.rawValue),
            URLQueryItem(name: "location_id", value: instance.location.rawValue),
            URLQueryItem(name: "launch_id", value: instance.instance),
            // Literally the string "undefined" on the wire — JavaScript's own
            // absent value stringified by the reference client. Reproduced
            // rather than omitted: an app reading `referrer_id` gets the same
            // thing every other client gives it, and an app that never reads it
            // is unaffected either way.
            URLQueryItem(name: "referrer_id", value: "undefined"),
            URLQueryItem(name: "custom_id", value: "undefined"),
            // This app has one ground and it is near-black. There is no light
            // theme to report, so this is a constant rather than a lookup.
            URLQueryItem(name: "theme", value: "dark"),
            URLQueryItem(name: "ui_density", value: "default"),
            URLQueryItem(
                name: "message_display_compact",
                value: string(AppSettings.shared.isCompactMode)
            ),
            // Percent, and Discord's own baseline is 100. This app stores a
            // multiplier over the same baseline, so the two agree at 1.0.
            URLQueryItem(
                name: "font_scale",
                value: String(Int((AppSettings.shared.textScale * 100).rounded()))
            ),
            URLQueryItem(name: "reduced_motion", value: string(prefersReducedMotion)),
            URLQueryItem(name: "high_contrast", value: string(prefersHighContrast)),
            // macOS has no "forced colors" mode — that is a Windows high-contrast
            // concept the web platform surfaces. Always false here, and stated
            // rather than dropped so the app sees the shape it expects.
            URLQueryItem(name: "forced_colors", value: "false"),
            URLQueryItem(name: "underline_links", value: "false"),
            URLQueryItem(name: "discord_proxy_ticket", value: proxyTicket),
            URLQueryItem(name: "channel_id", value: channelID.description),
            // Lowercased, and one per run. The app keys its own session on this,
            // so a URL rebuilt on a redraw would look like a reconnect.
            URLQueryItem(name: "frame_id", value: frameID.uuidString.lowercased()),
            URLQueryItem(name: "platform", value: "desktop"),
        ]
        // An activity in a Server Hub's own channel — the whiteboard — is told
        // so: Discord's `surface=5` (`51250`, `GUILD_SPACE` in its surface list).
        if isServerHubChannel {
            components.queryItems?.append(URLQueryItem(name: "surface", value: "5"))
        }
        return components.url
    }

    // MARK: The accessibility signals the frame is told about

    /// Read from the workspace rather than from `@Environment`.
    ///
    /// The URL is built by the session controller, which has no view to read an
    /// environment from — and this is a one-shot value baked into a URL, not a
    /// binding that has to track changes. An activity started before the
    /// setting was turned on keeps the value it launched with, which is the
    /// same thing that happens in the reference client.
    static var prefersReducedMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    static var prefersHighContrast: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    /// Lowercase, as JSON and as the capture spells it — `"false"`, never
    /// `"0"` and never Swift's own `"false"` by accident of interpolation.
    private static func string(_ flag: Bool) -> String { flag ? "true" : "false" }
}
