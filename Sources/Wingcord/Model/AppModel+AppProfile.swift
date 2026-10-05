import Foundation
import WingcordCore

/// The composer's app launcher, asked for at one app's page.
///
/// A token beside the app, for `StickerPickerRequest`'s reason: asking for the
/// same app twice is two requests, not one state.
struct AppLauncherRequest: Equatable, Sendable {
    var channelID: ChannelID
    var applicationID: ApplicationID
    var token: Int
}

// MARK: - An app's profile
//
// Discord's `BotUserProfileModal` buttons: Message (`982985`), Store
// (`571077`) and Add App / Open App (`570314`).

extension AppModel {

    /// Discord's `177640`: the open conversation is a direct message with an
    /// app — where its profile says Open App rather than Add App.
    var isInDirectMessageWithApp: Bool {
        guard let channelID = selectedChannelID, let channel = channelIndex[channelID],
              channel.guildID == nil, channel.recipientIDs.count == 1,
              let recipient = channel.recipientIDs.first
        else { return false }
        return users[recipient]?.isBot == true
    }

    /// Add App, from an app's profile — Discord's `692848.o`: the developer's
    /// own address where it has one, and Discord's sheet otherwise.
    ///
    /// **Discord's own authorize link stays here**, as Discord's link
    /// interceptor keeps it: a custom address that is just `oauth2/authorize`
    /// for this app is the sheet this client already has.
    func addApplication(from profile: ProfilePresentation) {
        guard let application = profile.application, application.isInstallable else { return }
        if let url = application.customInstallURL, !Self.isDiscordAuthorize(url, for: application.id) {
            openLink(url.absoluteString)
            return
        }
        profileApplicationInstall = ApplicationInstallRequest(
            applicationID: application.id,
            name: profile.displayName,
            iconHash: activityApp(application.id)?.iconHash,
            summary: ""
        )
    }

    /// Open App, in a direct message with an app — Discord's
    /// `OPEN_APP_LAUNCHER`: the composer's app launcher, at the app's page.
    func openApplicationLauncher(_ applicationID: ApplicationID) {
        guard let channelID = selectedChannelID else { return }
        profileRequest = nil
        activityLauncherPage = .app(applicationID)
        appLauncherRequest = AppLauncherRequest(
            channelID: channelID,
            applicationID: applicationID,
            token: (appLauncherRequest?.token ?? 0) &+ 1
        )
    }

    /// Store, from an app's profile: the app's storefront, which in this client
    /// is a page in discovery — Discord's is a modal over the profile.
    func openApplicationStore(_ applicationID: ApplicationID) {
        profileRequest = nil
        // The apps half under it, loaded, so Back lands on the app's page and
        // then on a grid with something in it.
        if var state = discovery == nil ? discoverySeed ?? DiscoveryState() : nil {
            state.tab = .apps
            discovery = state
            sessionController.loadDiscovery()
        } else {
            selectDiscoveryTab(.apps)
        }
        discovery?.openAppID = applicationID
        discovery?.openStoreID = applicationID
    }

    /// Whether a custom install address is only Discord's own authorize page
    /// for this application.
    static func isDiscordAuthorize(_ url: URL, for applicationID: ApplicationID) -> Bool {
        guard let host = url.host?.lowercased(),
              ["discord.com", "discordapp.com", "ptb.discord.com", "canary.discord.com"].contains(host),
              url.path.hasSuffix("/oauth2/authorize"),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return false }
        return components.queryItems?.first { $0.name == "client_id" }?.value == applicationID.description
    }
}
