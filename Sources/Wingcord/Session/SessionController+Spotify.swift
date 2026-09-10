import Foundation
import WingcordCore
import WingcordNet

// MARK: - The card behind a Spotify link
//
// **Resolved where the messages land, never from the projection that draws
// them** — the same rule the recent-activity list and the voice rows are held
// to. A fetch started inside a layout pass or a computed property runs during a
// view update, which is a state write in the middle of one.

extension SessionController {

    /// Asks Spotify for the cards behind any Spotify links in these messages.
    ///
    /// **Filtered to embeds Discord itself named Spotify**, so a message full of
    /// links costs one pass over its embeds and no requests. The provider is
    /// Discord's own answer — it unfurled the link and said whose it was — which
    /// is a cheaper and more reliable gate than parsing every URL in a
    /// transcript.
    ///
    /// Deduplicated three ways, because a channel is repetitive: an entity
    /// already resolved is skipped, one already in flight is skipped, and one
    /// Spotify has already refused is skipped for the rest of the session. The
    /// last is what stops a private playlist in somebody's backlog being asked
    /// for on every page of history.
    func resolveSpotifyUnfurls(in messages: [Message]) {
        var wanted: [(key: String, kind: SpotifyUnfurl.Kind, id: String)] = []
        for message in messages {
            for embed in message.embeds where embed.providerName == "Spotify" {
                guard let link = embed.url, let address = SpotifyLink.parse(link) else { continue }
                let key = "\(address.kind.rawValue)/\(address.id)"
                guard model.spotifyUnfurls[key] == nil,
                      !spotifyRefusals.contains(key),
                      !spotifyFetches.contains(key)
                else { continue }
                spotifyFetches.insert(key)
                wanted.append((key, address.kind, address.id))
            }
        }
        guard !wanted.isEmpty else { return }

        Task { [weak self] in
            guard let self else { return }
            var landed = false
            // **Sequentially, not in parallel.** A page of history can carry a
            // dozen of these and they are a third party's web pages, not an API
            // this client has a rate limiter for; a burst is the kind of thing
            // that gets an address throttled. The transcript already draws
            // Discord's card while they arrive.
            for entity in wanted {
                defer { spotifyFetches.remove(entity.key) }
                do {
                    guard let card = try await spotify.unfurl(
                        kind: entity.kind, id: entity.id
                    ) else {
                        // Not an error: a page that has stopped carrying the
                        // blob, or an entity Spotify will not show. Remembered
                        // so it is asked once.
                        spotifyRefusals.insert(entity.key)
                        continue
                    }
                    model.spotifyUnfurls[entity.key] = card
                    landed = true
                } catch {
                    // A transport failure is worth another try later — the
                    // reader may simply have been offline — so it is *not*
                    // remembered as a refusal.
                    Self.trace("spotify \(entity.key) failed: \(Self.describe(error))")
                }
            }
            // **One bump for the batch.** Each one relays out every row in the
            // transcript that carries a Spotify link, so bumping per answer
            // would relayout the channel a dozen times for one page.
            if landed { model.spotifyRevision &+= 1 }
        }
    }
}
