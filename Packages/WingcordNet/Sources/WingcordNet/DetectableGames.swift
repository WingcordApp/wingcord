import Foundation
import OSLog
import WingcordCore

// MARK: - Fetching Discord's detectable-games database
//
// **Not a `DiscordREST` route, deliberately**, and for the same reason the
// attachment `PUT` is not one: this is an unauthenticated file on the CDN, and
// putting it through the API client would attach the account token and a
// super-properties header to a request that needs neither and to a host that has
// no business seeing either.
//
// It is also 4.3 MB of JSON describing 24,323 games, which makes three things
// load-bearing rather than tidy:
//
//   * **ETag.** Discord's own client sends `If-None-Match` and treats 304 as
//     "keep what you have". The file changes rarely and re-downloading it on
//     every launch is four megabytes for nothing.
//   * **Disk.** The decoded catalog is cached beside the ETag, so a relaunch
//     costs a conditional GET rather than a download.
//   * **The 57% that is dropped at decode.** Only 10,451 of the 24,323 entries
//     carry `executables`; the rest are games Discord knows about but cannot
//     detect. They can never match anything, so they are discarded before they
//     cost a string allocation.

public struct DetectableGamesCatalog: Sendable {
    public var games: [DetectableGame]
    /// The ETag the CDN served this body with, for the next conditional GET.
    public var etag: String?

    public init(games: [DetectableGame], etag: String? = nil) {
        self.games = games
        self.etag = etag
    }
}

/// The detectable-games database, fetched and cached.
///
/// `nonisolated` throughout: decoding 4.3 MB of JSON is tens of milliseconds and
/// has no business happening on the main actor, and nothing here touches UI.
public enum DetectableGames {

    private static let log = Logger(subsystem: "dev.wingcord.Wingcord", category: "GameDetection")

    /// Where the client actually reads it.
    ///
    /// **The CDN, with the API route as a fallback** — which is the order
    /// Discord's own client uses: it builds the URL from `GLOBAL_ENV.CDN_HOST`
    /// and falls back to `/games/detectable` only when that is unset. The `-v1`
    /// suffix is on the CDN copy and not on the route.
    static let catalogURL = URL(string: "https://cdn.discordapp.com/detectables/games-v1.json")!

    /// Fetch the catalog, conditionally.
    ///
    /// - Parameter etag: the ETag of the copy already held, if any.
    /// - Returns: a fresh catalog, or `nil` when the server answered **304** and
    ///   the held copy is still current.
    public static func fetch(etag: String? = nil) async throws -> DetectableGamesCatalog? {
        var request = URLRequest(url: catalogURL)
        request.httpMethod = "GET"
        // Nothing of Discord's goes on this request. No token, no
        // super-properties, no locale. It is a static file.
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 304 {
            log.debug("detectables: 304, keeping the cached catalog")
            return nil
        }
        guard http.statusCode == 200 else {
            throw DetectableGamesError.badStatus(http.statusCode)
        }
        let served = http.value(forHTTPHeaderField: "ETag")
        let games = try decode(data)
        log.info("detectables: \(games.count, privacy: .public) detectable games")
        return DetectableGamesCatalog(games: games, etag: served)
    }

    // MARK: Decoding

    /// The wire shape, and the only three keys that matter.
    ///
    /// `third_party_skus` is on 19,524 entries and is not decoded: it maps a
    /// game to its Steam/Xbox/Battle.net product, which identifies a *purchase*
    /// rather than a running process. Nothing here resolves one.
    private struct GameDTO: Decodable {
        var id: ApplicationID?
        var name: String?
        var aliases: [String]?
        var executables: [ExecutableDTO]?

        struct ExecutableDTO: Decodable {
            var name: String?
            var os: String?
            var arguments: String?
            var is_launcher: Bool?
        }
    }

    static func decode(_ data: Data) throws -> [DetectableGame] {
        let raw = try JSONDecoder().decode([GameDTO].self, from: data)
        var games: [DetectableGame] = []
        // 10,451 of 24,323 in the file fetched 2026-09-14. Reserving the whole
        // count would hold twice the memory the result needs.
        games.reserveCapacity(raw.count / 2)
        for dto in raw {
            guard let id = dto.id, let name = dto.name,
                  let wire = dto.executables, !wire.isEmpty
            else { continue }
            let executables = wire.compactMap { entry -> DetectableExecutable? in
                guard let executableName = entry.name, !executableName.isEmpty,
                      let os = entry.os, let platform = DetectablePlatform(rawValue: os)
                else { return nil }
                return DetectableExecutable(
                    name: executableName,
                    platform: platform,
                    arguments: entry.arguments,
                    isLauncher: entry.is_launcher ?? false
                )
            }
            guard !executables.isEmpty else { continue }
            games.append(
                DetectableGame(
                    id: id,
                    name: name,
                    aliases: dto.aliases ?? [],
                    executables: executables
                )
            )
        }
        return games
    }
}

public enum DetectableGamesError: Error, Sendable {
    case badStatus(Int)
}

// MARK: - The cache on disk

/// The catalog, kept between launches.
///
/// **Application Support, never the working directory.** A 512 MB URL cache once
/// landed in the working directory in this project and nobody noticed for a
/// while; this is four megabytes and the same mistake would be just as invisible.
public enum DetectableGamesCache {

    private static let log = Logger(subsystem: "dev.wingcord.Wingcord", category: "GameDetection")

    private struct Stored: Codable {
        var etag: String?
        var games: [Entry]

        struct Entry: Codable {
            var id: UInt64
            var name: String
            var aliases: [String]
            var executables: [Executable]

            struct Executable: Codable {
                var name: String
                var os: String
                var arguments: String?
                var isLauncher: Bool
            }
        }
    }

    static var fileURL: URL? {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }
        return base
            .appendingPathComponent("Wingcord", isDirectory: true)
            .appendingPathComponent("detectable-games.json")
    }

    public static func load() -> DetectableGamesCatalog? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        guard let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            // A cache this client cannot read is a cache from an older shape.
            // Removed rather than left to fail on every launch.
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
        let games = stored.games.map { entry in
            DetectableGame(
                id: ApplicationID(rawValue: entry.id),
                name: entry.name,
                aliases: entry.aliases,
                executables: entry.executables.compactMap {
                    guard let platform = DetectablePlatform(rawValue: $0.os) else { return nil }
                    return DetectableExecutable(
                        name: $0.name,
                        platform: platform,
                        arguments: $0.arguments,
                        isLauncher: $0.isLauncher
                    )
                }
            )
        }
        return DetectableGamesCatalog(games: games, etag: stored.etag)
    }

    public static func save(_ catalog: DetectableGamesCatalog) {
        guard let fileURL else { return }
        let stored = Stored(
            etag: catalog.etag,
            games: catalog.games.map { game in
                Stored.Entry(
                    id: game.id.rawValue,
                    name: game.name,
                    aliases: game.aliases,
                    executables: game.executables.map {
                        Stored.Entry.Executable(
                            name: $0.name,
                            os: $0.platform.rawValue,
                            arguments: $0.arguments,
                            isLauncher: $0.isLauncher
                        )
                    }
                )
            }
        )
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try JSONEncoder().encode(stored).write(to: fileURL, options: .atomic)
        } catch {
            // A cache that cannot be written costs one download next launch and
            // nothing else, so it is logged rather than surfaced.
            log.warning("detectables: cache write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
