import Foundation
import WingcordCore
import WingcordNet

/// Keeps signed attachment links usable — Discord's refresh, for every surface
/// that fetches an upload.
///
/// **One place, under the fetch, rather than at each surface.** The viewer,
/// the transcript's prefetch, a film and a download all ask for the same files
/// by the same links, and a link that ran out fails all of them the same way.
/// So the stores ask here for the link to fetch with, and keep their cache
/// keys on the link they were given: a painter peeking with the old link still
/// finds the picture fetched with the new one.
///
/// **Batched and remembered.** A transcript scrolled to a day-old page asks for
/// thirty pictures at once; they go to Discord as one request, and a refreshed
/// signature is used for the rest of the session — the route answers a day's
/// worth of time with each one.
actor AttachmentLinks {
    static let shared = AttachmentLinks()

    private var client: DiscordREST?
    /// The file's canonical link → the same link, freshly signed.
    private var refreshed: [URL: URL] = [:]
    /// Links waiting for the next batch, and who is waiting on each.
    private var waiting: [URL: [CheckedContinuation<URL?, Never>]] = [:]
    private var flush: Task<Void, Never>?
    /// Links a 404 has already been answered for, so a file that is truly
    /// gone is asked about once and not on every hover.
    private var retried: Set<URL> = []

    /// The session's client — a refresh is the account's request like any
    /// other.
    func setClient(_ client: DiscordREST) {
        self.client = client
    }

    /// Signing out: another account's signatures are not this one's to use.
    func forget() {
        refreshed = [:]
        retried = []
    }

    /// The link to fetch `url` with: as it is while its signature has more
    /// than an hour left, otherwise freshly signed.
    func usable(_ url: URL) async -> URL {
        guard AttachmentLink.isSigned(url), let canonical = AttachmentLink.canonical(url) else { return url }
        if let fresh = refreshed[canonical], !AttachmentLink.needsRefresh(fresh) {
            return AttachmentLink.resigned(url, with: fresh)
        }
        guard AttachmentLink.needsRefresh(url) else { return url }
        guard let fresh = await refresh(canonical) else { return url }
        return AttachmentLink.resigned(url, with: fresh)
    }

    /// After the CDN refused `url`: a fresh signature regardless of what the
    /// old one said, once per file per session. Nil where there is nothing
    /// new to try.
    func retrying(_ url: URL) async -> URL? {
        guard AttachmentLink.isSigned(url), let canonical = AttachmentLink.canonical(url),
              retried.insert(canonical).inserted,
              let fresh = await refresh(canonical)
        else { return nil }
        return AttachmentLink.resigned(url, with: fresh)
    }

    private func refresh(_ canonical: URL) async -> URL? {
        guard client != nil else { return nil }
        return await withCheckedContinuation { continuation in
            waiting[canonical, default: []].append(continuation)
            if flush == nil {
                flush = Task { [weak self] in
                    // A beat for the rest of the page's pictures to join.
                    try? await Task.sleep(for: .milliseconds(40))
                    await self?.send()
                }
            }
        }
    }

    private func send() async {
        flush = nil
        let batch = waiting
        waiting = [:]
        guard let client, !batch.isEmpty else {
            for continuations in batch.values { for each in continuations { each.resume(returning: nil) } }
            return
        }
        // Discord's own client asks for one link at a time; fifty in one body
        // is well inside what the route takes and one rate-limit hit instead
        // of fifty.
        var answers: [String: String] = [:]
        let links = Array(batch.keys)
        for start in stride(from: 0, to: links.count, by: 50) {
            let chunk = links[start..<min(start + 50, links.count)].map(\.absoluteString)
            if let answered = try? await client.refreshAttachmentURLs(chunk) {
                answers.merge(answered) { _, new in new }
            }
        }
        for (canonical, continuations) in batch {
            let fresh = answers[canonical.absoluteString].flatMap(URL.init(string:))
            if let fresh { refreshed[canonical] = fresh }
            for each in continuations { each.resume(returning: fresh) }
        }
    }
}
