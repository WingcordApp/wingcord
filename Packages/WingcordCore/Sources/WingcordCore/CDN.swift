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

    /// A Server Hub's own banner — `/guild-space/{guild}/banner/{hash}`.
    public static func guildSpaceBanner(guildID: GuildID, hash: String, width: CGFloat, scale: CGFloat = 2) -> URL? {
        URL(string: "\(host)/guild-space/\(guildID.rawValue)/banner/\(hash).webp?size=\(rung(forSide: width, scale: scale))")
    }

    /// An Image + Text widget's picture —
    /// `/guild-space/{guild}/image-text-widget/{widget}/{hash}`.
    public static func guildSpaceWidgetImage(
        guildID: GuildID,
        widgetID: String,
        hash: String,
        width: CGFloat,
        scale: CGFloat = 2
    ) -> URL? {
        URL(string: "\(host)/guild-space/\(guildID.rawValue)/image-text-widget/\(widgetID)/\(hash).webp?size=\(rung(forSide: width, scale: scale))")
    }

    /// The wide artwork a server puts on its discovery card.
    ///
    /// **A third path, not a variant of the other two.** A guild's `banner`
    /// lives under `/banners/`, its `splash` under `/splashes/` and this under
    /// `/discovery-splashes/` — and the same server very often sends the same
    /// hash for two of them, which is exactly what makes a wrong path look like
    /// it works until it meets a server that does not.
    public static func guildDiscoverySplash(
        guildID: GuildID,
        hash: String,
        width: CGFloat,
        scale: CGFloat = 2
    ) -> URL? {
        let ext = fileExtension(animated: hash.hasPrefix("a_"))
        return URL(
            string: "\(host)/discovery-splashes/\(guildID.rawValue)/\(hash).\(ext)"
                + "?size=\(rung(forSide: width, scale: scale))"
        )
    }

    /// The picture behind an invite. The fallback where a server has no
    /// discovery splash of its own.
    /// A server's Server Guide header — the wide artwork Discord draws behind a
    /// support-server card.
    ///
    /// **`/home-headers/`, plural, at the top level.** Probed against `.fmbot`'s
    /// support guild: `/guilds/{id}/home-header/` 404s, `/guild-home-headers/`
    /// answers 403 and this answers 200. The field is `home_header` and the path
    /// is neither its name nor the shape the neighbouring splashes take, which
    /// is exactly why it is a function rather than a string at a call site.
    public static func guildHomeHeader(
        guildID: GuildID,
        hash: String,
        width: CGFloat,
        scale: CGFloat = 2
    ) -> URL? {
        URL(
            string: "\(host)/home-headers/\(guildID.rawValue)/\(hash).png"
                + "?size=\(rung(forSide: width, scale: scale))"
        )
    }

    public static func guildSplash(
        guildID: GuildID,
        hash: String,
        width: CGFloat,
        scale: CGFloat = 2
    ) -> URL? {
        let ext = fileExtension(animated: hash.hasPrefix("a_"))
        return URL(
            string: "\(host)/splashes/\(guildID.rawValue)/\(hash).\(ext)"
                + "?size=\(rung(forSide: width, scale: scale))"
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
    /// The poster, and the frame a plate rests on. `animatedNameplate(asset:)`
    /// is the same artwork moving.
    public static func nameplate(asset: String) -> URL? {
        guard !asset.isEmpty else { return nil }
        return URL(string: "\(host)/assets/collectibles/\(asset)static.png")
    }

    /// The moving form of the same strip.
    ///
    /// **`asset.webm`, and it is VP9 with alpha in a WebM container** — which
    /// neither AVFoundation nor `CGImageSource` can open on any Apple platform.
    /// It is reachable because this client demuxes it: `WebMDemuxer` finds the
    /// frames, `VP9Decoder` puts them through VideoToolbox's VP9 decoder, and
    /// the alpha arrives as a second VP9 bitstream beside each one. The result
    /// is the same filmstrip a GIF becomes.
    ///
    /// Confirmed live alongside the negatives already recorded for the still:
    /// `animated.gif`, `asset.png` and `static.webp` all 404, and this answers
    /// 200 with `video/webm`. No size rung — the route serves one authored
    /// 672x126 rendition and ignores a `size` query, exactly as the still does.
    ///
    /// **Not every plate has one.** A nameplate whose `.webm` 404s is a still,
    /// and `AnimatedImageStore` records that answer rather than asking again.
    public static func animatedNameplate(asset: String) -> URL? {
        guard !asset.isEmpty else { return nil }
        return URL(string: "\(host)/assets/collectibles/\(asset)asset.webm")
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
    /// A Server Guide step's or resource's uploaded picture, at Discord's 128
    /// (`getNewMemberActionIconURL` / `getResourceChannelIconURL`), keyed by
    /// the channel it points at.
    public static func guideIcon(kind: GuideIconKind, channelID: ChannelID, hash: String) -> URL? {
        let ext = hash.hasPrefix("a_") ? "gif" : "png"
        return URL(string: "\(host)/\(kind.rawValue)/\(channelID.rawValue)/\(hash).\(ext)?size=128")
    }

    public enum GuideIconKind: String, Sendable {
        case step = "new-member-actions"
        case resource = "resource-channels"
    }

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

    /// A personal widget's picture — Discord's own address (build 643186,
    /// `326009`'s `m`): `/widget-assets/{owner}/{file_id}`, as WebP, moving
    /// when asked. **Keyed by the widget's owner**, which is why a picture
    /// could not be drawn from the widget alone.
    public static func widgetAsset(owner: UserID, fileID: String, animated: Bool) -> URL? {
        URL(string: "\(host)/widget-assets/\(owner.rawValue)/\(fileID)?format=webp&animated=\(animated)")
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

    /// What an application with no `icon` is drawn as.
    ///
    /// **Not on the CDN host, and not derived from anything.** It is a static
    /// asset of the web client — `discord.com/assets/aa9bb230adf0286f.png`, a
    /// 184-pixel blurple disc — and Discord's own directory falls back to it
    /// rather than to the bot's avatar: OWO Admin has `icon: null` with a
    /// `bot.avatar` set, and its page draws this.
    ///
    /// **It is also what the gradient is derived from** for such an app, which
    /// is the reason it is a URL here rather than a bundled picture: the palette
    /// has to quantise the same bytes Discord does. Checked — it answers
    /// `rgb(107,124,196)` → `rgb(107,196,135)`, which is what Discord's page
    /// shows.
    public static let defaultApplicationIcon =
        URL(string: "https://discord.com/assets/aa9bb230adf0286f.png")

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

    /// A game's icon, banner, cover or artwork, from the hash `/games` sends.
    ///
    /// **All four live in `/app-icons/`, and the reference's CDN table names
    /// none of them.** The table has an entry for an application's icon, cover
    /// and splash and one for a game *screenshot*, and nothing for
    /// `media.banner`, `media.artwork` or `media.cover` when they arrive as
    /// hashes. Probed live against The Sims 4's banner hash
    /// `4bf8d6cf…` and Arknights' cover hash `ad75eaf2…`:
    /// `/app-assets/{id}/{hash}.png` answers 404, so do
    /// `/app-assets/{id}/game/{hash}.png`, `…/game/artworks/…` and
    /// `…/game/covers/…`; `/app-icons/{id}/{hash}.png` answers 200 for every one
    /// of them, and honours `?size=`.
    ///
    /// So this is `applicationCover`'s path, and it is a separate function
    /// because it is a separate *fact* — one probed against game media rather
    /// than against an application's `cover_image` — and because a caller
    /// holding a `Game` should not have to know they coincide.
    public static func gameAsset(
        id: ApplicationID,
        hash: String,
        side: CGFloat,
        scale: CGFloat = 2
    ) -> URL? {
        URL(
            string: "\(host)/app-icons/\(id.rawValue)/\(hash).png"
                + "?size=\(rung(forSide: side, scale: scale))"
        )
    }

    /// One of a game's screenshots, for the games whose shots Discord hosts
    /// rather than proxying from IGDB.
    public static func gameScreenshot(
        id: ApplicationID,
        hash: String,
        width: CGFloat,
        scale: CGFloat = 2
    ) -> URL? {
        URL(
            string: "\(host)/app-assets/\(id.rawValue)/game/screenshots/\(hash).png"
                + "?size=\(rung(forSide: width, scale: scale))"
        )
    }

    /// The still the preview loop starts on.
    ///
    /// **The same asset id, with `.png` instead of `.mp4`.** Probed live against
    /// Farm Merge Valley's `1232355776870223923`: `.mp4`, `.png` and `.jpg` all
    /// answer 200 at that path, and the PNG is 512x288 — the video's own first
    /// frame at 16:9. Nothing in any capture names it; it was found by asking
    /// the path the video already lives at for a picture.
    ///
    /// It is what a card in the directory grid draws at rest, so the loop that
    /// starts on hover begins from the frame that was already on screen.
    public static func activityPreviewPoster(
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

    /// A game trailer, which is a store asset and therefore `.mp4` under
    /// `/store/` — the same shape `activityPreviewVideo` already probed.
    public static func gameTrailer(id: ApplicationID, assetID: String) -> URL? {
        URL(string: "\(host)/app-assets/\(id.rawValue)/store/\(assetID).mp4")
    }

    /// A trailer's poster: the same store asset asked for as `.webp` — what
    /// Discord's game profile hands its `<video>` as `poster`, and its tray as
    /// the thumbnail (module `371794`, `YE(app, asset, width, "webp")`).
    public static func gameTrailerPoster(
        id: ApplicationID,
        assetID: String,
        width: CGFloat,
        scale: CGFloat = 2
    ) -> URL? {
        URL(
            string: "\(host)/app-assets/\(id.rawValue)/store/\(assetID).webp"
                + "?size=\(rung(forSide: width, scale: scale))"
        )
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
    ///
    /// **The picture's own shape, always** — measured on the live proxy,
    /// 2026-11-18, on a 1672×941 PNG (docs/BETA3.md §1.4). Discord changed it
    /// since 2026-09-29, when it fitted a picture inside the box and never
    /// cropped it: it now **crops to whatever box it is given** —
    /// `width=808&height=3232` came back 808×3232, a 1:4 slice of the middle —
    /// and refuses either side past 4096 with a 400 (4096 answers, 4097 does
    /// not). Given only a width it still answers with the original untouched.
    ///
    /// So the box is never invented. `height`, when the caller passes one, is
    /// the box the picture is drawn into, cropped there anyway (a square
    /// thumbnail, a grid cell); otherwise the height comes from `sourceSize`,
    /// the picture's own pixels, which every attachment and embed carries. A
    /// box past the file's own size shrinks to it — the proxy would only
    /// enlarge it — and either side past 4096 shrinks both. With neither, the
    /// answer is the original: a bigger download, but the right picture, where
    /// four widths used to come back as a sliver or a 400 and left only the
    /// blurred placeholder on screen.
    ///
    /// **A GIF keeps every frame**: a 32-frame Tenor GIF at `width=200&height=150`
    /// came back a 32-frame GIF at 150x150. What flattens one to a single frame
    /// is `format=webp`, which Discord's client sends only for stills — module
    /// `776231` adds no format for an animated source.
    ///
    /// - Parameter animated: asks for every frame. **An animated WebP is
    ///   flattened to its first frame unless asked**, resized or not — measured
    ///   2026-09-29: one frame bare and at `width=200&height=194`, all 133 with
    ///   `animated=true` — while a GIF comes back byte-identical either way.
    ///   Discord's client sends it for the pictures it plays as moving; pass
    ///   `playsAsAnimated`.
    public static func resizedAttachment(
        proxyURL: String,
        width: CGFloat,
        height: CGFloat? = nil,
        sourceSize: CGSize? = nil,
        animated: Bool = false,
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
        var items = components.queryItems ?? []
        items.removeAll {
            $0.name == "width" || $0.name == "height" || $0.name == "format" || $0.name == "animated"
        }
        if let box = proxyBox(width: width, height: height, sourceSize: sourceSize, scale: scale) {
            items.append(URLQueryItem(name: "width", value: String(box.width)))
            items.append(URLQueryItem(name: "height", value: String(box.height)))
        }
        if animated { items.append(URLQueryItem(name: "animated", value: "true")) }
        components.queryItems = items.isEmpty ? nil : items
        return components.url
    }

    /// The most the media proxy draws on either side (measured 2026-11-18).
    public static let proxyLimit = 4096

    /// The pixel box to ask the proxy for, or nil for the original.
    ///
    /// See `resizedAttachment`: the proxy crops to the box, so the box is the
    /// caller's own (`height`) or the picture's shape (`sourceSize`), never past
    /// the file's own pixels and never past `proxyLimit` on either side.
    public static func proxyBox(
        width: CGFloat,
        height: CGFloat?,
        sourceSize: CGSize?,
        scale: CGFloat
    ) -> (width: Int, height: Int)? {
        let source = sourceSize.flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil }
        var boxWidth = (width * scale).rounded(.up)
        var boxHeight: CGFloat
        if let height {
            boxHeight = (height * scale).rounded(.up)
        } else if let source {
            boxHeight = boxWidth * source.height / source.width
        } else {
            return nil
        }
        guard boxWidth > 0, boxHeight > 0 else { return nil }
        // Past the file's own size the proxy only enlarges: shrink the box,
        // keeping its shape, until it fits inside the picture.
        if let source {
            let fit = min(1, source.width / boxWidth, source.height / boxHeight)
            boxWidth *= fit
            boxHeight *= fit
        }
        let limit = CGFloat(proxyLimit)
        let cap = min(1, limit / max(boxWidth, boxHeight))
        boxWidth *= cap
        boxHeight *= cap
        return (max(1, Int(boxWidth.rounded())), max(1, Int(boxHeight.rounded())))
    }

    /// Whether Discord's client plays a picture as moving — its
    /// `LazyImage.isAnimated`, read from the bundle (web `d4c7976eccf337f1`).
    ///
    /// **A `.gif` always, and a `.webp` or `.avif` only when Discord marked it
    /// `IS_ANIMATED`.** A WebP's extension says nothing, since one is either,
    /// and the mark is the server's own reading of the file: captured on both
    /// GIF attachments in the HARs and on animated embed media, and on no still.
    /// Nothing else moves — a PNG included, which Discord's client asks the
    /// proxy to turn into a WebP. A `.gif` of one frame still counts, as it
    /// does there: a browser shows one as a still, and so must whatever plays
    /// it here (`FilmPlayer`'s `drawsStills`).
    ///
    /// - Parameter url: the picture's own URL — the attachment's or the
    ///   media's `url` — which is the one Discord tests first.
    public static func playsAsAnimated(_ url: String, isMarkedAnimated: Bool) -> Bool {
        let path = url.prefix { $0 != "?" && $0 != "#" }.lowercased()
        if path.hasSuffix(".gif") { return true }
        return isMarkedAnimated && (path.hasSuffix(".webp") || path.hasSuffix(".avif"))
    }

    /// A still frame from a video attachment.
    ///
    /// **A video's own URL is not a picture, and asking for one as if it were is
    /// how a clip draws as an empty box.** The bytes arrive, `CGImageSource`
    /// cannot open them, the store records a permanent failure, and the slot
    /// stays grey for the life of the process — which is exactly the symptom
    /// "videos have no preview" describes.
    ///
    /// Discord's media proxy transcodes: an image `format` on a video path
    /// answers with a still from it. **`webp`, as Discord's own client asks**
    /// (`591818`'s `j`, and `ImageComponentForMessageAttachment`: the proxy URL
    /// with `format=webp` is every video's poster there) — the one format the
    /// proxy is certain to serve for a video, because it is the one Discord's
    /// own posters depend on. ImageIO decodes WebP.
    ///
    /// Nil when the proxy cannot serve it — anything that is not `http(s)` is a
    /// local fixture or somebody else's host, and appending a query there is a
    /// URL that 404s rather than a smaller picture. The caller draws its
    /// placeholder, which is the honest answer.
    /// Both sides, for the reason `resizedAttachment` gives.
    public static func videoPoster(
        proxyURL: String, width: CGFloat, height: CGFloat? = nil, sourceSize: CGSize? = nil, scale: CGFloat = 2
    ) -> URL? {
        guard var components = URLComponents(string: proxyURL),
              let scheme = components.scheme,
              scheme == "http" || scheme == "https"
        else { return nil }
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "width" || $0.name == "height" || $0.name == "format" }
        items.append(URLQueryItem(name: "format", value: "webp"))
        // The same box rule as a picture's (`resizedAttachment`): the proxy
        // crops a still to the box it is given, and refuses one past 4096.
        if let box = proxyBox(width: width, height: height, sourceSize: sourceSize, scale: scale) {
            items.append(URLQueryItem(name: "width", value: String(box.width)))
            items.append(URLQueryItem(name: "height", value: String(box.height)))
        }
        components.queryItems = items
        return components.url
    }
}
