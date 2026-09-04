import Foundation

/// Builds Discord CDN URLs.
///
/// Pure string work, no networking, so it lives beside the models and can be
/// called from a painter running off the main actor.
///
/// **Every builder takes a drawn side in points and rounds it to a CDN rung.**
/// That is not a convenience — it is the fix for the two ways an avatar comes
/// out wrong. Ask for an asset larger than the slot and the compositor is handed
/// an oversized texture to minify at draw time, which is what a blurry icon
/// actually is; ask for one smaller and it is upscaled. Both ends have to be
/// sized: the rung requested here, and the pixel size the decoder is told to
/// decode to.
public enum CDN {
    public static let host = "https://cdn.discordapp.com"
    public static let mediaHost = "https://media.discordapp.net"

    /// The sizes Discord actually serves. Anything else is rounded up to one of
    /// these server-side, so asking for 100 costs the same as asking for 128 and
    /// returns 128.
    static let rungs: [Int] = [16, 32, 64, 80, 96, 128, 160, 256, 320, 512, 600, 1024, 2048, 4096]

    /// The smallest rung that covers a slot of `side` points at `scale`.
    ///
    /// Backing scale is a parameter rather than a lookup because this runs off
    /// the main actor, where asking a window for its scale is neither possible
    /// nor meaningful.
    public static func rung(forSide side: CGFloat, scale: CGFloat = 2) -> Int {
        let pixels = Int((side * scale).rounded(.up))
        return rungs.first { $0 >= pixels } ?? rungs[rungs.count - 1]
    }

    /// An animated asset is served as GIF; a static one as WebP, which is
    /// roughly a third the bytes of PNG at the same quality and which every
    /// Apple platform decodes natively.
    private static func fileExtension(animated: Bool) -> String {
        animated ? "gif" : "webp"
    }

    /// Whether a URL this type built can animate at all.
    ///
    /// The extension is a **complete** answer for banners, icons and emoji,
    /// because it was chosen from the hash's own `a_` prefix on the way out. A
    /// complete answer here is worth having: a still banner that is *asked*
    /// whether it animates costs a second download of the same bytes, a
    /// multi-frame decode to discover there is one frame, and a view and a
    /// coordinator to hold the answer — for the majority of assets, which are
    /// still.
    ///
    /// Avatar decorations are the exception and must not be tested with this:
    /// they are always PNG and usually animated, so only a decode can tell.
    public static func canAnimate(_ url: URL) -> Bool {
        url.pathExtension == "gif"
    }

    public static func avatar(
        userID: UserID,
        hash: String,
        side: CGFloat,
        scale: CGFloat = 2
    ) -> URL? {
        let ext = fileExtension(animated: hash.hasPrefix("a_"))
        return URL(
            string: "\(host)/avatars/\(userID.rawValue)/\(hash).\(ext)?size=\(rung(forSide: side, scale: scale))"
        )
    }

    /// The per-guild avatar override, which beats the account avatar wherever
    /// that guild is the context.
    public static func guildMemberAvatar(
        guildID: GuildID,
        userID: UserID,
        hash: String,
        side: CGFloat,
        scale: CGFloat = 2
    ) -> URL? {
        let ext = fileExtension(animated: hash.hasPrefix("a_"))
        return URL(
            string: "\(host)/guilds/\(guildID.rawValue)/users/\(userID.rawValue)/avatars/\(hash).\(ext)"
                + "?size=\(rung(forSide: side, scale: scale))"
        )
    }

    /// The fallback for an account with no avatar. Always PNG and always 256 —
    /// it is a flat colour with a glyph, so there is nothing a larger rung buys
    /// and no animated form to ask for.
    public static func defaultAvatar(index: Int) -> URL? {
        URL(string: "\(host)/embed/avatars/\(index).png")
    }

    public static func guildIcon(
        guildID: GuildID,
        hash: String,
        side: CGFloat,
        scale: CGFloat = 2
    ) -> URL? {
        let ext = fileExtension(animated: hash.hasPrefix("a_"))
        return URL(
            string: "\(host)/icons/\(guildID.rawValue)/\(hash).\(ext)?size=\(rung(forSide: side, scale: scale))"
        )
    }

    public static func guildBanner(
        guildID: GuildID,
        hash: String,
        width: CGFloat,
        scale: CGFloat = 2
    ) -> URL? {
        let ext = fileExtension(animated: hash.hasPrefix("a_"))
        return URL(
            string: "\(host)/banners/\(guildID.rawValue)/\(hash).\(ext)?size=\(rung(forSide: width, scale: scale))"
        )
    }

    public static func userBanner(
        userID: UserID,
        hash: String,
        width: CGFloat,
        scale: CGFloat = 2
    ) -> URL? {
        let ext = fileExtension(animated: hash.hasPrefix("a_"))
        return URL(
            string: "\(host)/banners/\(userID.rawValue)/\(hash).\(ext)?size=\(rung(forSide: width, scale: scale))"
        )
    }

    /// A custom emoji. Animated ones are GIF; the size rung matters here more
    /// than anywhere, because an inline emoji is drawn at 20pt and the source is
    /// 128.
    public static func emoji(
        id: EmojiID,
        animated: Bool,
        side: CGFloat,
        scale: CGFloat = 2
    ) -> URL? {
        URL(
            string: "\(host)/emojis/\(id.rawValue).\(fileExtension(animated: animated))"
                + "?size=\(rung(forSide: side, scale: scale))"
        )
    }

    /// An avatar decoration — the ring or frame drawn around an avatar. Always
    /// PNG: these are authored with alpha and Discord does not serve a WebP
    /// rendition.
    public static func avatarDecoration(hash: String) -> URL? {
        URL(string: "\(host)/avatar-decoration-presets/\(hash).png?size=160&passthrough=true")
    }

    /// The strip drawn behind a roster row.
    ///
    /// **`asset` already ends in a slash** — Discord sends
    /// `"nameplates/dark_roses/1526656194121568256/"` — so the file name is
    /// appended rather than joined, and this takes the path exactly as sent.
    ///
    /// No size rung: the route serves one authored 672x126 PNG and ignores a
    /// `size` query. Confirmed against a live asset, along with the file name —
    /// `static.png` answers 200 and `asset.png`, `static.webp` and
    /// `animated.gif` all 404.
    ///
    /// **The animated form is deliberately not offered.** It exists, at
    /// `asset.webm`, and it is VP9-with-alpha in a WebM container — which
    /// AVFoundation cannot demux on any Apple platform. Reaching it would mean
    /// a hand-written demuxer plus a frame clock per visible roster row, and
    /// the still is what this client draws.
    public static func nameplate(asset: String) -> URL? {
        guard !asset.isEmpty else { return nil }
        return URL(string: "\(host)/assets/collectibles/\(asset)static.png")
    }

    /// One layer of a profile frame.
    ///
    /// **A different host path from every other collectible**, and not
    /// guessable from them: nameplates and avatar decorations live under
    /// `/assets/`, while a frame's layers are served from the shop's own media
    /// route and are addressed by the *layer's* id under the *product's* SKU.
    /// The payload carries no `src` for them at all, only the ids — so this is
    /// the whole of how a frame becomes pictures.
    ///
    /// Always `static`: `animated`, `asset` and `preview` all 404 on a live
    /// layer, which is why a frame needs no clock.
    public static func profileFrameLayer(sku: String, layerID: String) -> URL? {
        URL(string: "\(host)/media/v1/collectibles-shop/\(sku)/\(layerID)/static")
    }

    /// A group DM's icon.
    public static func channelIcon(
        channelID: ChannelID,
        hash: String,
        side: CGFloat,
        scale: CGFloat = 2
    ) -> URL? {
        URL(
            string: "\(host)/channel-icons/\(channelID.rawValue)/\(hash).webp"
                + "?size=\(rung(forSide: side, scale: scale))"
        )
    }

    /// An account badge — Nitro, HypeSquad, a bug hunter mark.
    ///
    /// Discord serves these as authored artwork rather than as anything a symbol
    /// can stand in for, and the profile route names them by hash. Always PNG:
    /// they carry alpha and are drawn at sixteen points, so a larger rung buys
    /// nothing.
    /// A soundboard clip.
    ///
    /// **No extension and no size.** The route serves the uploaded audio
    /// directly — Ogg Opus for most, MP3 for some of Discord's own — and the
    /// decoder is told what it is by the bytes rather than by the URL. Appending
    /// a format here 404s.
    public static func soundboardSound(id: String) -> URL? {
        URL(string: "\(host)/soundboard-sounds/\(id)")
    }

    public static func accountBadge(hash: String) -> URL? {
        URL(string: "\(host)/badge-icons/\(hash).png?size=64")
    }

    /// The header artwork on a server's tag profile.
    ///
    /// The route answers with two hashes: `banner_hash`, which is the ordinary
    /// boost banner most servers do not have, and `custom_banner_hash`, which is
    /// the one the tag profile actually shows. **Both are requested from the
    /// same `/banners/` path, and the second of those is the one asset path in
    /// this file that has not been confirmed against a live response** — a wrong
    /// path 404s, and a 404 here falls back to the plate the header draws while
    /// loading, which is the same picture a server with no banner gets.
    public static func guildProfileBanner(
        guildID: GuildID,
        hash: String,
        width: CGFloat,
        scale: CGFloat = 2
    ) -> URL? {
        guildBanner(guildID: guildID, hash: hash, width: width, scale: scale)
    }

    /// An app's own icon.
    ///
    /// **Two path segments, not one** — `/app-icons/{application_id}/{hash}`.
    /// Confirmed against the CDN reference; a hash alone 404s.
    /// `side` is points, as everywhere else here; the default is the 32pt slot
    /// the profile card's app chip draws into, which resolves to the `size=64`
    /// this took before it was given a size at all.
    public static func applicationIcon(
        id: ApplicationID,
        hash: String,
        side: CGFloat = 32,
        scale: CGFloat = 2
    ) -> URL? {
        URL(
            string: "\(host)/app-icons/\(id.rawValue)/\(hash).png"
                + "?size=\(rung(forSide: side, scale: scale))"
        )
    }

    /// The wide artwork above an app's detail page, and behind its tile in the
    /// launcher's featured row.
    ///
    /// **`/app-icons/`, not `/app-assets/`** — the surprising part, and the
    /// reason this is a function rather than a call site building a string.
    /// `cover_image` is a different picture from `icon` and it is a different
    /// shape, but it hangs off the same path; probed live against Watch
    /// Together's `3cc9446876ae9eec6e06ff565703c292`,
    /// `/app-assets/{id}/store/{hash}.png` answers 404 and this answers 200.
    public static func applicationCover(
        id: ApplicationID,
        hash: String,
        width: CGFloat,
        scale: CGFloat = 2
    ) -> URL? {
        URL(
            string: "\(host)/app-icons/\(id.rawValue)/\(hash).png"
                + "?size=\(rung(forSide: width, scale: scale))"
        )
    }

    /// A **store** asset — a subscription's thumbnail, an item's header, a
    /// benefit's icon.
    ///
    /// **A different path from an app's registered assets**, and the one place
    /// `/app-assets/{id}/store/` is correct: the launcher already learned that
    /// this path 404s for a `cover_image`, which is a different asset space
    /// reached through `/app-icons/`. These ids come from `store-layout` and
    /// they live under `store`.
    public static func storeAsset(
        id: ApplicationID,
        assetID: String,
        width: CGFloat,
        scale: CGFloat = 2
    ) -> URL? {
        URL(
            string: "\(host)/app-assets/\(id.rawValue)/store/\(assetID).png"
                + "?size=\(rung(forSide: width, scale: scale))"
        )
    }

    /// One of an application's registered assets, by id.
    ///
    /// The shelf's `assets` map answers `{id, type, name}` per application and
    /// every entry in a captured response is `type: 1` — an image. A caller
    /// that finds another type must not route it here.
    public static func applicationAsset(
        id: ApplicationID,
        assetID: String,
        side: CGFloat,
        scale: CGFloat = 2
    ) -> URL? {
        URL(
            string: "\(host)/app-assets/\(id.rawValue)/\(assetID).png"
                + "?size=\(rung(forSide: side, scale: scale))"
        )
    }

    /// The looping preview on an activity's detail page.
    ///
    /// **`/store/` in the middle, and `.mp4`.** `activity_preview_video_asset_id`
    /// is an asset id that appears in no `assets` map — those hold images only
    /// — so its path cannot be inferred from a neighbouring one. Probed live:
    /// `/app-assets/{id}/{asset}.mp4` 404s, `.webm` answers 400,
    /// `/activity-preview-videos/…` 403s, and this answers 200.
    ///
    /// No `size` rung: it is a video, and the query the image paths take is
    /// meaningless on one.
    public static func activityPreviewVideo(id: ApplicationID, assetID: String) -> URL? {
        URL(string: "\(host)/app-assets/\(id.rawValue)/store/\(assetID).mp4")
    }

    /// The badge that rides inside a clan tag chip.
    ///
    /// Always PNG and always small: it is drawn at eleven points beside nine-point
    /// letters, so there is nothing a larger rung buys.
    /// A scheduled event's cover.
    ///
    /// `guild-events/`, not `guild-event-covers/` — the path does not follow
    /// the field's name, which is `image`.
    public static func scheduledEventCover(
        eventID: UInt64,
        hash: String,
        side: CGFloat = 320,
        scale: CGFloat = 2
    ) -> URL? {
        URL(
            string: "\(host)/guild-events/\(eventID)/\(hash).png"
                + "?size=\(rung(forSide: side, scale: scale))"
        )
    }

    public static func guildTagBadge(guildID: GuildID, hash: String) -> URL? {
        URL(string: "\(host)/clan-badges/\(guildID.rawValue)/\(hash).png?size=32")
    }

    public static func roleIcon(
        roleID: RoleID,
        hash: String,
        side: CGFloat,
        scale: CGFloat = 2
    ) -> URL? {
        URL(
            string: "\(host)/role-icons/\(roleID.rawValue)/\(hash).webp"
                + "?size=\(rung(forSide: side, scale: scale))"
        )
    }

    public static func sticker(id: UInt64, format: StickerRef.Format) -> URL? {
        switch format {
        case .lottie:
            URL(string: "\(host)/stickers/\(id).json")
        case .gif:
            URL(string: "\(mediaHost)/stickers/\(id).gif")
        case .png, .apng, .unknown:
            URL(string: "\(host)/stickers/\(id).png?size=320")
        }
    }

    /// Rewrites an attachment URL to request a resized rendition from the media
    /// proxy.
    ///
    /// The proxy accepts `width`/`height` query parameters and returns a scaled
    /// image; the raw `cdn.discordapp.com` URL does not. Downloading a 12-megapixel
    /// phone photo to draw it 400pt wide is the single largest avoidable cost on
    /// an image-heavy channel, and this is where it is avoided.
    public static func resizedAttachment(
        proxyURL: String,
        width: CGFloat,
        scale: CGFloat = 2
    ) -> URL? {
        guard var components = URLComponents(string: proxyURL) else {
            return URL(string: proxyURL)
        }
        // **Only Discord's proxy resizes.** A query appended to anything else —
        // a `file:` URL under `--demo`, an asset served from somewhere this
        // client did not choose — is not a smaller picture, it is a URL that
        // 404s, and the failure looks exactly like a missing attachment.
        guard let scheme = components.scheme, scheme == "http" || scheme == "https" else {
            return components.url
        }
        let pixels = Int((width * scale).rounded(.up))
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "width" || $0.name == "height" || $0.name == "format" }
        items.append(URLQueryItem(name: "width", value: String(pixels)))
        // Height is deliberately left to the proxy so the aspect ratio is
        // preserved; asking for both forces a crop.
        components.queryItems = items
        return components.url
    }
}
