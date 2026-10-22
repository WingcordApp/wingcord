import Foundation

// MARK: - League's Live Client Data
//
// Riot's documented game-client API (developer.riotgames.com/docs/lol, "Game
// Client API"): `https://127.0.0.1:2999/liveclientdata/…`, answering only while
// a match runs. **Its certificate is self-signed** — Riot's own root, which
// Riot publishes for clients to check against — so the trust here is narrowed
// to that one address and port instead: nothing else this app talks to gets
// a pass.

final class LeagueLiveClient: Sendable {
    private static let base = URL(string: "https://127.0.0.1:2999/liveclientdata/")!

    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.urlCache = nil
        let delegate = TrustLocalLeague()
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    /// The reader's Riot ID, `name#tag` — the body is one JSON string.
    func activePlayerName() async throws -> String {
        let data = try await get("activeplayername")
        guard let name = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String,
              !name.isEmpty
        else { throw URLError(.cannotParseResponse) }
        return name
    }

    /// `eventdata`, and the game clock it was read at.
    func events() async throws -> (Data, Double?) {
        let events = try await get("eventdata")
        let stats = try? await get("gamestats")
        let gameTime = stats
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .flatMap { ($0["gameTime"] as? NSNumber)?.doubleValue }
        return (events, gameTime)
    }

    private func get(_ path: String) async throws -> Data {
        let (data, response) = try await session.data(from: Self.base.appendingPathComponent(path))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }
}

/// Trusts League's self-signed certificate at 127.0.0.1:2999, and nothing else.
private final class TrustLocalLeague: NSObject, URLSessionDelegate, Sendable {
    func urlSession(
        _ session: URLSession, didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              space.host == "127.0.0.1", space.port == 2999,
              let trust = space.serverTrust
        else { return (.performDefaultHandling, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }
}
