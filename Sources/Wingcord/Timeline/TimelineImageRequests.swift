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
            case film
        }

        static func == (lhs: Request, rhs: Request) -> Bool { lhs.key == rhs.key }
        func hash(into hasher: inout Hasher) { hasher.combine(key) }
    }

    /// - Parameter loadsArtwork: The reader's "load images automatically"
    ///   preference. Avatars, emoji and stickers ignore it — a transcript
    ///   without them is unreadable rather than merely plainer — and the two
    ///   expensive buckets honour it.
    /// - Parameter onActivityIcon: An activity invitation's colour is quantised
    ///   from the same icon this fetches, so the derivation is kicked off beside
    ///   the fetch rather than waiting for a second trigger. A callback because
    ///   this type must not reach the store.
    static func requests(
        for rows: [MessageRow],
        scale: CGFloat,
        loadsArtwork: Bool,
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
                    let film = AnimatedImageStore.Key(
                        url: key.url, maximumPixelSize: key.maximumPixelSize
                    )
                    if AnimatedImageStore.shared.cached(film) == nil,
                       !AnimatedImageStore.shared.isKnownStill(film)
                    {
                        requests.append(Request(key: key, source: .film))
                    }
                } else if ImageStore.shared.cached(key, bucket: .artwork) == nil {
                    requests.append(Request(key: key, source: .still(.artwork)))
                }
            }

            // An embed's own pictures: an author's mark, a thumbnail, the main
            // image, a footer icon. The painter only peeks, so anything nobody
            // prefetches never appears.
            for image in row.embeds.lazy.flatMap(\.images) {
                guard loadsArtwork, let url = image.url else { continue }
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
                    let film = AnimatedImageStore.Key(
                        url: key.url, maximumPixelSize: key.maximumPixelSize
                    )
                    if AnimatedImageStore.shared.cached(film) == nil,
                       !AnimatedImageStore.shared.isKnownStill(film)
                    {
                        requests.append(Request(key: key, source: .film))
                    }
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
            for slot in row.attachments where !slot.isSpoiler && slot.carriesArtwork {
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
                    let film = AnimatedImageStore.Key(
                        url: key.url, maximumPixelSize: key.maximumPixelSize
                    )
                    if AnimatedImageStore.shared.cached(film) == nil,
                       !AnimatedImageStore.shared.isKnownStill(film)
                    {
                        requests.append(Request(key: key, source: .film))
                    }
                } else if ImageStore.shared.cached(key, bucket: .attachment) == nil {
                    requests.append(Request(key: key, source: .still(.attachment)))
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
                    if seen.insert(key).inserted, ImageStore.shared.cached(key) == nil {
                        requests.append(Request(key: key, source: .still(.thumbnail)))
                    }
                }
            }
        }
        return requests
    }

}
