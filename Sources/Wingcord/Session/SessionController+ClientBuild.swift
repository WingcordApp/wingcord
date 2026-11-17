import Foundation
import WingcordNet

// MARK: - Keeping the client's build number current
//
// See `ClientBuildCache` and `DiscordWebBuild`: Discord refuses its newest
// routes to an old `client_build_number`, so the number this client sends is
// re-read off discord.com/app once a day and used from the next launch.

extension SessionController {

    /// Reads Discord's current web build in the background when the last
    /// reading is a day old. Never in the demo, and never in the way of the
    /// connection: this session keeps the number it started with.
    func refreshClientBuildIfStale() {
        guard !LaunchOptions.current.usesDemoFixtures else { return }
        let cache = ClientBuildCache()
        guard cache.isStale() else { return }
        let userAgent = metadata.userAgent
        let sent = metadata.baseline.webBuildNumber
        Task.detached(priority: .utility) {
            let number = await DiscordWebBuild.fetch(userAgent: userAgent)
            cache.record(number)
            let reading = number.map(String.init) ?? "unreadable"
            Self.trace("client build: page says \(reading), this session sends \(sent)")
        }
    }
}
