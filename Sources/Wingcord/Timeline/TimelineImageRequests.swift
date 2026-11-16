import AppKit
import Foundation
import WingcordCore

/// Which pictures a set of laid-out message rows needs.
///
/// **One builder, shared by every surface that draws messages.** The painter
/// only *peeks* — starting a fetch per row per display pass would be a hundred
/// allocations a frame for pictures already in flight — so somewhere has to ask
/// for the bytes once. The trap `INVARIANTS.md` §2 names is that an asset kind
/// added to the painter and not to this list is an asset **nobody ever
/// fetches**, and it draws as a permanent placeholder. A second copy of this
/// function for a second surface is that trap with an extra step: the transcript
/// and the pinned pane draw the same rows with the same painter, so they ask for
/// the same pictures from one place.
///
/// The key built here must equal the key the painter peeks with, or the picture
/// lands in a slot the draw never looks in.
nonisolated enum TimelineImageRequests {

    struct Request: Hashable {
        var key: ImageStore.Key
        /// Which store answers. A Lottie sticker has no bitmap on the CDN at
        /// all, so its poster is the first frame of a rasterised filmstrip and
        /// lives in the other cache entirely.
        var source: Source

        enum Source: Hashable {
            case still(ImageStore.Bucket)
            /// A picture that may move, and the bucket its painter falls back
            /// to if it turns out to be one frame — nil where there is no still
            /// to fall back to, as for a Lottie sticker.
            case film(still: ImageStore.Bucket?)
        }

        static func == (lhs: Request, rhs: Request) -> Bool { lhs.key == rhs.key }
        func hash(into hasher: inout Hasher) { hasher.combine(key) }

        /// Fetches what this names into the cache its painter peeks. Every
        /// surface that draws message rows loads its batch through here.
        ///
        /// **A film that turns out to be one frame is fetched as the still at
        /// once**, rather than on the next viewport change — which, on a list
        /// nobody is scrolling, never comes.
        ///
        /// - Returns: whether anything landed, so a surface repaints once per
        ///   batch rather than once per picture.
        func load() async -> Bool {
            switch source {
            case .still(let bucket):
                return await ImageStore.shared.image(for: key, bucket: bucket) != nil
            case .film(let bucket):
                let film = AnimatedImageStore.Key(url: key.url, maximumPixelSize: key.maximumPixelSize)
                if await AnimatedImageStore.shared.image(for: film) != nil { return true }
                guard let bucket, AnimatedImageStore.shared.isKnownStill(film) else { return false }
                return await ImageStore.shared.image(for: key, bucket: bucket) != nil
            }
        }
    }

    /// The request for a picture that may move: its film — or, once the film
    /// store has learned it is a single frame, the still its painter falls
    /// back to in `bucket`. Nil when whichever it needs is already held.
    ///
    /// **A "GIF" of one frame is common** — a caption meme saved as a GIF so it
    /// can be favourited — and the film store answers nil for one. Every
    /// painter falls back to the still, and nothing ever asked for it: on every
    /// surface that plays films on the clock, the picture was a plate for good.
    private static func moving(_ key: ImageStore.Key, still bucket: ImageStore.Bucket?) -> Request? {
        let film = AnimatedImageStore.Key(url: key.url, maximumPixelSize: key.maximumPixelSize)
        if AnimatedImageStore.shared.isKnownStill(film) {
            guard let bucket, ImageStore.shared.cached(key, bucket: bucket) == nil else { return nil }
            return Request(key: key, source: .still(bucket))
        }
        return AnimatedImageStore.shared.cached(film) == nil
            ? Request(key: key, source: .film(still: bucket))
            : nil
    }

    /// The pictures a conversation's head draws: the person's or the group's
    /// face, and the servers in common. Keyed as `drawAvatar` peeks — the
    /// box's own size, the thumbnail bucket.
    static func requests(forHead slot: ConversationStartSlot, scale: CGFloat) -> [Request] {
        var faces: [(URL, CGFloat)] = []
        if let url = slot.avatarURL { faces.append((url, slot.iconRect.width)) }
        for icon in slot.mutuals?.icons ?? [] {
            if let url = icon.mark.iconURL { faces.append((url, icon.rect.width)) }
        }
        return faces.compactMap { url, side in
            let key = ImageStore.Key(url: url, maximumPixelSize: Int((side * scale).rounded(.up)))
            return ImageStore.shared.cached(key) == nil ? Request(key: key, source: .still(.thumbnail)) : nil
        }
    }

    /// - Parameter loadsArtwork: The reader's "load images automatically"
    ///   preference. Avatars, emoji and stickers ignore it — a transcript
    ///   without them is unreadable rather than merely plainer — and the two
    ///   expensive buckets honour it.
    /// - Parameter onActivityIcon: An activity invitation's colour is quantised
    ///   from the same icon this fetches, so the derivation is kicked off beside
    ///   the fetch rather than waiting for a second trigger. A callback because
    ///   this type must not reach the store.
    /// - Parameter playsAnimatedEmoji: whether an animated custom emoji is
    ///   worth a multi-frame decode. Passed in rather than read here because
    ///   this type is `nonisolated` and the answer is two main-actor reads —
    ///   see `AnimationClock.playsAnimatedEmoji`. A still emoji is unaffected:
    ///   the tag says which kind it is.
    /// - Parameter filmsOnLayers: whether the surface plays its moving
    ///   pictures on layers — the transcript's `TranscriptFilms` — which load
    ///   their own frames. A filmstrip decoded here as well would be the same
    ///   picture decoded twice, once into a cache nothing reads.
    static func requests(
        for rows: [MessageRow],
        scale: CGFloat,
        loadsArtwork: Bool,
        playsAnimatedEmoji: Bool = true,
        filmsOnLayers: Bool = false,
        /// The spoilered attachments the reader has uncovered, by message — a
        /// spoiler's picture is fetched only once it is drawn.
        revealedAttachments: (MessageID) -> Set<Int> = { _ in [] },
        /// The same for a forward's own files.
        revealedForwardAttachments: (MessageID) -> Set<Int> = { _ in [] },
        onActivityIcon: ((ActivityInvite) -> Void)? = nil
    ) -> [Request] {
        var requests: [Request] = []
        var seen = Set<ImageStore.Key>()

        for row in rows {

            if let url = row.avatarURL {
                let key = ImageStore.Key(
                    url: url,
                    maximumPixelSize: Int((Metrics.avatarMessage * scale).rounded(.up))
                )
                if seen.insert(key).inserted, ImageStore.shared.cached(key) == nil {
                    requests.append(Request(key: key, source: .still(.thumbnail)))
                }
            }

            // **The avatar decoration, which was decoded and never asked
            // for.** `MessageRow.decorationURL` has been filled by the layout
            // since the row was written and nothing requested the bytes, so
            // every decoration in the transcript drew as nothing. The painter
            // only peeks — §2 — and the key has to equal the one it peeks with.
            if let url = row.decorationURL, row.avatarRect != nil {
                let side = Metrics.avatarMessage * Metrics.decorationScale
                let key = ImageStore.Key(
                    url: url,
                    maximumPixelSize: Int((side * scale).rounded(.up))
                )
                if seen.insert(key).inserted, ImageStore.shared.cached(key) == nil {
                    requests.append(Request(key: key, source: .still(.thumbnail)))
                }
            }

            // The role icon beside the name. Same peek-only rule as everything
            // else here: it draws as a hole without this.
            if let url = row.roleIconURL, row.roleIconRect.width > 0 {
                let key = ImageStore.Key(
                    url: url,
                    maximumPixelSize: Int((row.roleIconRect.width * scale).rounded(.up))
                )
                if seen.insert(key).inserted, ImageStore.shared.cached(key) == nil {
                    requests.append(Request(key: key, source: .still(.thumbnail)))
                }
            }

            // The badge inside a server tag. Small — eleven points — and the
            // painter only peeks, so without this every tag in the transcript
            // draws its letters and a hole where the badge goes.
            if let url = row.tagBadgeURL {
                let key = ImageStore.Key(
                    url: url,
                    maximumPixelSize: Int(
                        (MemberRowGeometry.tagBadgeSide * scale).rounded(.up)
                    )
                )
                if seen.insert(key).inserted, ImageStore.shared.cached(key) == nil {
                    requests.append(Request(key: key, source: .still(.thumbnail)))
                }
            }

            // A drawn card's faces — AutoMod's own, the member it acted on,
            // whoever switched Activity Alerts on — keyed at the box's size, as
            // the painter peeks them.
            for part in row.card?.parts ?? [] {
                guard case .avatar(let url?, _, let rect) = part else { continue }
                let key = ImageStore.Key(url: url, maximumPixelSize: Int((rect.width * scale).rounded(.up)))
                if seen.insert(key).inserted, ImageStore.shared.cached(key) == nil {
                    requests.append(Request(key: key, source: .still(.thumbnail)))
                }
            }

            // The quoted face above a reply. **Requested at the message
            // avatar's size and drawn at sixteen points**, so a reply to
            // somebody already on screen costs nothing at all — the painter
            // peeks the same slot with the same key. See `drawReplyHeader`.
            if let url = row.replyHeader?.avatarURL {
                let key = ImageStore.Key(
                    url: url,
                    maximumPixelSize: Int((Metrics.avatarMessage * scale).rounded(.up))
                )
                if seen.insert(key).inserted, ImageStore.shared.cached(key) == nil {
                    requests.append(Request(key: key, source: .still(.thumbnail)))
                }
            }

            // Stickers. **The painter only ever peeks**, so an asset nobody
            // prefetches is an asset that never arrives — which is the whole of
            // "stickers render as blank space". The key has to match the
            // painter's exactly, or the picture lands in a slot the draw never
            // looks in.
            for slot in row.stickers {
                guard let url = slot.url else { continue }
                let key = ImageStore.Key(
                    url: url,
                    maximumPixelSize: Int((slot.rect.width * scale).rounded(.up))
                )
                guard seen.insert(key).inserted else { continue }
                // **A moving sticker needs its FILMSTRIP, not its first frame.**
                // Asking for the still gave a picture that never changed, which
                // is the whole of "stickers do not animate in the chat": every
                // APNG and GIF sticker was decoded once, at frame zero, and
                // there was nothing for the clock to advance through.
                if slot.isAnimated {
                    guard !filmsOnLayers else { continue }
                    // Lottie has no bitmap on the CDN — see `stickerFrame`.
                    if let request = moving(key, still: slot.isVector ? nil : .artwork) {
                        requests.append(request)
                    }
                } else if ImageStore.shared.cached(key, bucket: .artwork) == nil {
                    requests.append(Request(key: key, source: .still(.artwork)))
                }
            }

            // An embed's own pictures: an author's mark, a thumbnail, the main
            // image, a footer icon. The painter only peeks, so anything nobody
            // prefetches never appears.
            for image in row.embeds.lazy.flatMap(\.images) {
                // A spoiler's picture is never drawn, so it is never fetched.
                guard loadsArtwork, !image.isSpoiler, let url = image.url else { continue }
                let bucket: ImageStore.Bucket = image.isArtwork ? .artwork : .thumbnail
                let key = ImageStore.Key(
                    url: url,
                    maximumPixelSize: Int((image.decodeWidth * scale).rounded(.up))
                )
                guard seen.insert(key).inserted else { continue }
                // A pasted GIF link unfurls into one of these and it moves, so
                // it needs the filmstrip rather than frame zero — the same rung
                // stickers and attachments ride.
                if image.isAnimated {
                    guard !filmsOnLayers else { continue }
                    if let request = moving(key, still: bucket) { requests.append(request) }
                } else if ImageStore.shared.cached(key, bucket: bucket) == nil {
                    requests.append(Request(key: key, source: .still(bucket)))
                }
            }

            // **Custom emoji inside an embed or a Components V2 card.** The
            // painter only peeks, so an app's `<:sakura:123>` in a description
            // is a blank gap until somebody asks for the bytes — and nothing
            // else on this pass does.
            for text in row.embeds.lazy.flatMap(\.texts) {
                for entry in text.block.emojiRects {
                    guard let id = entry.emoji.id,
                          let url = CDN.emoji(
                              id: id, animated: entry.emoji.isAnimated, side: entry.rect.width
                          )
                    else { continue }
                    let key = ImageStore.Key(
                        url: url,
                        maximumPixelSize: Int((entry.rect.width * scale).rounded(.up))
                    )
                    if seen.insert(key).inserted, ImageStore.shared.cached(key) == nil {
                        requests.append(Request(key: key, source: .still(.thumbnail)))
                    }
                }
            }

            // An activity invitation's app icon. It is the card's only picture,
            // and — unlike everything else on this pass — it is *also* what the
            // card's colour is quantised from, so the derivation is kicked off
            // beside the fetch rather than waiting for a second trigger.
            if let invite = row.activityInvite, let url = invite.iconURL {
                onActivityIcon?(invite.source)
                let key = ImageStore.Key(
                    url: url,
                    maximumPixelSize: Int((invite.iconRect.width * scale).rounded(.up))
                )
                if seen.insert(key).inserted, ImageStore.shared.cached(key) == nil {
                    requests.append(Request(key: key, source: .still(.thumbnail)))
                }
            }

            // A shared theme card's face of who shared it.
            if let theme = row.sharedTheme {
                for picture in theme.pictures {
                    let key = ImageStore.Key(
                        url: picture.url, maximumPixelSize: Int((picture.rect.width * scale).rounded(.up))
                    )
                    if seen.insert(key).inserted, ImageStore.shared.cached(key) == nil {
                        requests.append(Request(key: key, source: .still(.thumbnail)))
                    }
                }
            }

            // An invite card's splash, icon and the face of who sent it.
            for card in row.inviteCards {
                for picture in card.pictures {
                    let key = InviteCardSlot.imageKey(picture.url, in: picture.rect, scale: scale)
                    if seen.insert(key).inserted, ImageStore.shared.cached(key) == nil {
                        requests.append(Request(key: key, source: .still(.thumbnail)))
                    }
                }
            }

            // A poll's answer glyphs.
            for answer in row.poll?.answers ?? [] {
                guard let id = answer.emoji?.id,
                      let url = CDN.emoji(
                          id: id,
                          animated: answer.emoji?.isAnimated ?? false,
                          side: answer.emojiRect.width
                      )
                else { continue }
                let key = ImageStore.Key(
                    url: url,
                    maximumPixelSize: Int((answer.emojiRect.width * scale).rounded(.up))
                )
                if seen.insert(key).inserted, ImageStore.shared.cached(key) == nil {
                    requests.append(Request(key: key, source: .still(.thumbnail)))
                }
            }

            // **The emoji on reaction chips, which nothing asked for.** The
            // painter peeked for them and this pass never requested one, so
            // every custom emoji under a message drew as a grey plate for the
            // life of the channel — the trap this type exists to close, missed
            // for one asset kind. Keyed exactly as `drawReactionGlyph` peeks:
            // the chip's own URL at the glyph's side. An emoji with both a plain
            // and a super chip is one request; the key is the same.
            for slot in row.reactions {
                guard let url = slot.imageURL else { continue }
                let key = ImageStore.Key(
                    url: url,
                    maximumPixelSize: Int((TimelineMetrics.reactionGlyphSide * scale).rounded(.up))
                )
                guard seen.insert(key).inserted else { continue }
                // The strip for an animated one, as for an inline emoji, so a
                // reaction moves the way the same emoji in the text above does.
                if slot.emoji.isAnimated, playsAnimatedEmoji {
                    guard !filmsOnLayers else { continue }
                    if let request = moving(key, still: .thumbnail) { requests.append(request) }
                } else if ImageStore.shared.cached(key) == nil {
                    requests.append(Request(key: key, source: .still(.thumbnail)))
                }
            }

            // A button's emoji rides the ordinary inline-emoji rung.
            for slot in row.components {
                guard let id = slot.emoji?.id,
                      let url = CDN.emoji(
                          id: id,
                          animated: slot.emoji?.isAnimated ?? false,
                          side: TimelineMetrics.componentGlyphSide
                      )
                else { continue }
                let key = ImageStore.Key(
                    url: url,
                    maximumPixelSize: Int(
                        (TimelineMetrics.componentGlyphSide * scale).rounded(.up)
                    )
                )
                if seen.insert(key).inserted, ImageStore.shared.cached(key) == nil {
                    requests.append(Request(key: key, source: .still(.thumbnail)))
                }
            }

            // A message's own files. **Only the kinds that carry a picture** —
            // a voice note and a document draw from the layout alone, and a
            // request for their bytes would be a download of the whole file to
            // decode nothing.
            // **A spoiler's picture once it is uncovered**: before, it is
            // never drawn and so never fetched — and it used to stay that way
            // after the reveal, an empty plate where the picture should be.
            let revealed = row.attachments.contains(where: \.isSpoiler) ? revealedAttachments(row.id) : []
            for (index, slot) in row.attachments.enumerated()
            where slot.carriesArtwork && (!slot.isSpoiler || revealed.contains(index)) {
                // A clip's faces, keyed as `drawClipHeader` peeks them — faces,
                // not artwork, so they come whatever the artwork setting.
                for face in slot.clip?.faces ?? [] {
                    guard let url = face.url else { continue }
                    let key = ImageStore.Key(
                        url: url,
                        maximumPixelSize: Int((ClipTileHeader.faceSide * scale).rounded(.up))
                    )
                    if seen.insert(key).inserted, ImageStore.shared.cached(key) == nil {
                        requests.append(Request(key: key, source: .still(.thumbnail)))
                    }
                }
                guard loadsArtwork, let url = slot.url else { continue }
                let key = ImageStore.Key(
                    url: url,
                    maximumPixelSize: Int((slot.decodeWidth * scale).rounded(.up))
                )
                guard seen.insert(key).inserted else { continue }
                // **A GIF needs its FILMSTRIP, not its first frame** — the same
                // rule the stickers above follow, and the same failure if it is
                // missed: the picture is decoded once, at frame zero, and there
                // is nothing for the clock to advance through.
                if slot.isAnimated {
                    guard !filmsOnLayers else { continue }
                    if let request = moving(key, still: .attachment) { requests.append(request) }
                } else if ImageStore.shared.cached(key, bucket: .attachment) == nil {
                    requests.append(Request(key: key, source: .still(.attachment)))
                }
            }

            // **A forward's own pictures, which nothing asked for** (Alex,
            // 2026-11-16: "media from forwarded messages doesn't even load").
            // The painter peeks them like everything else, so a forwarded
            // photograph, sticker or link card stayed a grey plate unless some
            // other surface had happened to fetch the same bytes. Keyed exactly
            // as `drawForward` peeks.
            if let forward = row.forwarded {
                for slot in forward.stickers {
                    guard let url = slot.url else { continue }
                    let key = ImageStore.Key(url: url, maximumPixelSize: Int((slot.rect.width * scale).rounded(.up)))
                    guard seen.insert(key).inserted else { continue }
                    if slot.isAnimated {
                        guard !filmsOnLayers else { continue }
                        if let request = moving(key, still: slot.isVector ? nil : .artwork) { requests.append(request) }
                    } else if ImageStore.shared.cached(key, bucket: .artwork) == nil {
                        requests.append(Request(key: key, source: .still(.artwork)))
                    }
                }
                let revealed = forward.attachments.contains(where: \.isSpoiler)
                    ? revealedForwardAttachments(row.id) : []
                for (index, slot) in forward.attachments.enumerated()
                where slot.carriesArtwork && (!slot.isSpoiler || revealed.contains(index)) {
                    guard loadsArtwork, let url = slot.url else { continue }
                    let key = ImageStore.Key(url: url, maximumPixelSize: Int((slot.decodeWidth * scale).rounded(.up)))
                    guard seen.insert(key).inserted else { continue }
                    if slot.isAnimated {
                        guard !filmsOnLayers else { continue }
                        if let request = moving(key, still: .attachment) { requests.append(request) }
                    } else if ImageStore.shared.cached(key, bucket: .attachment) == nil {
                        requests.append(Request(key: key, source: .still(.attachment)))
                    }
                }
                for image in forward.embeds.lazy.flatMap(\.images) {
                    guard loadsArtwork, !image.isSpoiler, let url = image.url else { continue }
                    let bucket: ImageStore.Bucket = image.isArtwork ? .artwork : .thumbnail
                    let key = ImageStore.Key(url: url, maximumPixelSize: Int((image.decodeWidth * scale).rounded(.up)))
                    guard seen.insert(key).inserted else { continue }
                    if image.isAnimated {
                        guard !filmsOnLayers else { continue }
                        if let request = moving(key, still: bucket) { requests.append(request) }
                    } else if ImageStore.shared.cached(key, bucket: bucket) == nil {
                        requests.append(Request(key: key, source: .still(bucket)))
                    }
                }
                // The words' custom emoji when they are not the row's own text
                // — the row's own are asked for below.
                let texts = forward.embeds.flatMap(\.texts).map(\.block)
                    + (forward.bodyIsRowText ? [] : [forward.body].compactMap(\.self))
                for block in texts {
                    for entry in block.emojiRects {
                        guard let id = entry.emoji.id,
                              let url = CDN.emoji(id: id, animated: entry.emoji.isAnimated, side: entry.rect.width)
                        else { continue }
                        let key = ImageStore.Key(url: url, maximumPixelSize: Int((entry.rect.width * scale).rounded(.up)))
                        if seen.insert(key).inserted, ImageStore.shared.cached(key) == nil {
                            requests.append(Request(key: key, source: .still(.thumbnail)))
                        }
                    }
                }
                if let url = forward.footerIconURL {
                    let key = ImageStore.Key(
                        url: url, maximumPixelSize: Int((forward.footerIconRect.width * scale).rounded(.up))
                    )
                    if seen.insert(key).inserted, ImageStore.shared.cached(key) == nil {
                        requests.append(Request(key: key, source: .still(.thumbnail)))
                    }
                }
            }

            if let block = row.textBlock {
                for entry in block.emojiRects {
                    guard let id = entry.emoji.id,
                          let url = CDN.emoji(
                              id: id,
                              animated: entry.emoji.isAnimated,
                              side: entry.rect.width
                          )
                    else { continue }
                    let key = ImageStore.Key(
                        url: url,
                        maximumPixelSize: Int((entry.rect.width * scale).rounded(.up))
                    )
                    guard seen.insert(key).inserted else { continue }
                    // **An animated emoji needs the strip, not the still.** The
                    // tag says which kind it is — `<a:name:id>` — so a still one
                    // costs no multi-frame decode and no clock subscription
                    // spent discovering an answer that arrived with the text.
                    // Without this rung the painter peeks a filmstrip that
                    // nothing ever asked for and every custom emoji in the
                    // transcript sits on frame zero.
                    if entry.emoji.isAnimated, playsAnimatedEmoji {
                        guard !filmsOnLayers else { continue }
                        if let request = moving(key, still: .thumbnail) { requests.append(request) }
                    } else if ImageStore.shared.cached(key) == nil {
                        requests.append(Request(key: key, source: .still(.thumbnail)))
                    }
                }
            }
        }
        return requests
    }

    /// The same requests, in the order the rows are given, each with the
    /// messages that draw it — so a surface repaints just those rows when the
    /// picture lands (`ImageBatch`), not the whole canvas.
    ///
    /// Row by row through the one builder above, which keeps its dedup per row;
    /// a picture several rows share is asked for once and remembered for all
    /// of them.
    static func requestsByMessage(
        for rows: [MessageRow],
        scale: CGFloat,
        loadsArtwork: Bool,
        playsAnimatedEmoji: Bool = true,
        filmsOnLayers: Bool = false,
        revealedAttachments: (MessageID) -> Set<Int> = { _ in [] },
        revealedForwardAttachments: (MessageID) -> Set<Int> = { _ in [] },
        onActivityIcon: ((ActivityInvite) -> Void)? = nil
    ) -> (requests: [Request], owners: [ImageStore.Key: [MessageID]]) {
        var requests: [Request] = []
        var owners: [ImageStore.Key: [MessageID]] = [:]
        for row in rows {
            let asked = Self.requests(
                for: [row],
                scale: scale,
                loadsArtwork: loadsArtwork,
                playsAnimatedEmoji: playsAnimatedEmoji,
                filmsOnLayers: filmsOnLayers,
                revealedAttachments: revealedAttachments,
                revealedForwardAttachments: revealedForwardAttachments,
                onActivityIcon: onActivityIcon
            )
            for request in asked {
                if owners[request.key] == nil { requests.append(request) }
                owners[request.key, default: []].append(row.id)
            }
        }
        return (requests, owners)
    }
}
