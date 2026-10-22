import Foundation
import WingcordCore

// MARK: - What the profile editor's flyouts read
//
// docs/CLIPS-PRESENCE.md, Phase 9. The flyouts open and close often while a
// profile is being edited, so what they show is asked for once and kept — and
// `--demo` answers from fixtures, because it makes no requests at all.

extension AppModel {

    /// The reader's cosmetics of one kind, from the one purchases route.
    func ownedCollectibles(of kind: CollectibleKind) async throws -> [OwnedCollectible] {
        if let cached = ownedCollectiblesCache {
            return cached.filter { $0.kind == kind }
        }
        let all = LaunchOptions.current.usesDemoFixtures
            ? DemoCollectibles.owned
            : try await sessionController.rest.ownedCollectibles()
        ownedCollectiblesCache = all
        return all.filter { $0.kind == kind }
    }

    /// The avatars Discord still holds for the reader.
    func recentAvatars() async throws -> [RecentAvatar] {
        if let cached = recentAvatarsCache { return cached }
        let recents = LaunchOptions.current.usesDemoFixtures
            ? []
            : try await sessionController.rest.recentAvatars()
        recentAvatarsCache = recents
        return recents
    }

    /// The four GIFs on Choose GIF's tile — trending ones, asked once. Discord
    /// draws four bundled GIFs there; this client ships none of Discord's art.
    func loadGIFMosaic() {
        guard !gifMosaicRequested else { return }
        gifMosaicRequested = true
        Task {
            let landing = try? await sessionController.gifLanding()
            gifMosaic = Array((landing?.trending ?? []).compactMap(\.previewURL).prefix(4))
        }
    }

    /// Asks for an effect's or a frame's product, once, where nothing has
    /// resolved it — so a cosmetic chosen in the editor can be drawn before it
    /// is saved. `--demo` seeds its products and asks for none.
    func resolveCollectible(sku: String) {
        guard profileEffects[sku] == nil, profileFrames[sku] == nil,
              !LaunchOptions.current.usesDemoFixtures
        else { return }
        sessionController.loadCollectible(sku: sku)
    }

    /// The reader's own colours, out of their avatar — what the colour
    /// flyout offers first. Empty until `loadArtworkColours` has landed.
    func artworkColours(of profile: ProfilePresentation) -> [UInt32] {
        guard let url = profile.avatarURL.flatMap(paletteURL(for:)) else { return [] }
        return derivedPalettes[url] ?? []
    }

    /// Quantises the avatar once — a CDN picture, not an API request, so
    /// `--demo` may too.
    func loadArtworkColours(of profile: ProfilePresentation) {
        guard let url = profile.avatarURL.flatMap(paletteURL(for:)), derivedPalettes[url] == nil
        else { return }
        sessionController.derivePalette(at: url)
    }

    /// An avatar's address at the palette's own rendition.
    private func paletteURL(for avatar: URL) -> URL? {
        guard var parts = URLComponents(url: avatar, resolvingAgainstBaseURL: false),
              parts.host?.hasSuffix("discordapp.com") == true || parts.host?.hasSuffix("discordapp.net") == true
        else { return nil }
        var query = (parts.queryItems ?? []).filter { $0.name != "size" }
        query.append(URLQueryItem(name: "size", value: String(ProfileThemePalette.profilePixelSize)))
        parts.queryItems = query
        return parts.url
    }
}

// MARK: - Saving in `--demo`

extension AppModel {
    /// `--demo` makes no requests, so a save has nowhere to go: the draft is
    /// written onto the reader's own fixture instead, and the editor can be
    /// tried end to end. A server's profile, and pictures that were never
    /// uploaded, have no fixture to land on and are left as they were.
    func applyDemoProfileEdit(_ editor: ProfileEditor) {
        if editor.widgets != profileWidgets[editor.userID] ?? [] {
            profileWidgets[editor.userID] = editor.widgets
        }
        guard editor.scope == .account, let user = users[editor.userID] else { return }
        let old = user.decoration
        let worn: [WornCollectible] = [
            editor.profileEffectSKU.map { WornCollectible(skuID: $0, kind: .profileEffect) },
            editor.profileFrameSKU.map { WornCollectible(skuID: $0, kind: .profileFrame) },
        ].compactMap(\.self)
        let decoration = UserDecoration(
            avatarDecorationHash: editor.avatarDecorationSKU == nil
                ? nil
                : editor.decorationAsset ?? old?.avatarDecorationHash,
            avatarDecorationSKU: editor.avatarDecorationSKU,
            nameplate: editor.nameplate,
            displayNameStyle: editor.displayNameStyle,
            bannerHash: editor.banner == .removed ? nil : old?.bannerHash,
            accentColor: editor.accentColor,
            bio: editor.bio.isEmpty ? nil : editor.bio,
            themeColorValues: editor.themeColors,
            badges: old?.badges ?? [],
            profileEffectSKU: editor.profileEffectSKU,
            profileFrameSKU: editor.profileFrameSKU,
            wornCollectibles: worn,
            pronouns: editor.pronouns.isEmpty ? nil : editor.pronouns,
            connectedAccounts: old?.connectedAccounts ?? [],
            premiumTier: old?.premiumTier ?? .none,
            premiumSince: old?.premiumSince,
            legacyUsername: old?.legacyUsername,
            mutualGuilds: old?.mutualGuilds ?? [],
            mutualFriends: old?.mutualFriends ?? [],
            isProfilePrivate: old?.isProfilePrivate ?? false,
            primaryGuildTag: old?.primaryGuildTag,
            primaryGuildBadgeHash: old?.primaryGuildBadgeHash,
            primaryGuildID: old?.primaryGuildID,
            application: old?.application
        )
        users[editor.userID] = User(
            id: user.id,
            username: user.username,
            displayName: editor.displayName.isEmpty ? user.displayName : editor.displayName,
            avatarHash: editor.avatar == .removed ? nil : user.avatarHash,
            discriminator: user.discriminator,
            flags: user.flags,
            isBot: user.isBot,
            isSystem: user.isSystem,
            decoration: decoration.isEmpty ? nil : decoration
        )
        ownTypingIndicatorStyle = editor.typingIndicatorStyle
        identityRevision &+= 1
    }
}
