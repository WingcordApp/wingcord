import Foundation
import WingcordCore

// The two routes behind the Activity tab.
//
// Both were captured in one session on a live account — a profile popout opened
// on somebody playing Counter-Strike through Medal — and the capture is the
// reason each is shaped the way it is below.

extension DiscordREST {

    /// The links behind an activity's custom buttons.
    ///
    /// **A presence sends the button LABELS and never their URLs.** That is the
    /// whole reason this route exists: `buttons: ["Follow on Medal", "Download
    /// Medal"]` arrives over the gateway, and the two addresses those open come
    /// back only from here — captured as
    /// `{"button_urls": ["https://medal.tv/u/…?ref=discordrpc",
    /// "https://medal.tv/?ref=discordrpc"]}`.
    ///
    /// **Both ids are the activity's own.** The session id is on the activity
    /// object, not on the presence and not on the user; an activity without one
    /// cannot be addressed here at all, and its buttons are therefore not drawn.
    ///
    /// A 204 means the activity published none, and is answered with an empty
    /// array rather than an error: "this app has no button links" is a normal
    /// outcome for nearly every activity on Discord.
    public func activityMetadata(
        of userID: UserID,
        session: String,
        application: ApplicationID
    ) async throws -> ActivityMetadata {
        let data = try await requestData(
            method: "GET",
            path: "/users/\(userID.rawValue)/sessions/\(session)"
                + "/activities/\(application.rawValue)/metadata",
            route: "users/{id}/sessions/:session/activities/:application/metadata",
            body: Optional<Never>.none
        )
        guard !data.isEmpty else { return ActivityMetadata() }
        let payload = try Self.decoder.decode(ActivityMetadataDTO.self, from: data)
        return ActivityMetadata(
            buttonURLs: (payload.button_urls ?? []).compactMap(URL.init(string:))
        )
    }

    /// Somebody's recent activity.
    ///
    /// **The outbox, not the inbox.** `/content-inventory/users/@me` is the
    /// reader's own feed of what *other* people did and wraps each entry in
    /// `{"content": …, "rank": n}`; the outbox is one person's own record and
    /// sends the content objects bare. The profile draws the second.
    public func recentActivity(of userID: UserID) async throws -> [RecentActivity] {
        try await get(
            "/content-inventory/users/\(userID.rawValue)/outbox",
            route: "content-inventory/users/{id}/outbox",
            as: ContentOutboxDTO.self
        ).entries?.compactMap(\.domain) ?? []
    }
}

/// What an activity published beyond its presence.
///
/// One field today. It is a struct rather than a bare array because the route
/// answers with an object — `artist_ids`, `album_id`, `context_uri` and `type`
/// ride alongside `button_urls` for a Spotify session — and a client that
/// decoded the array directly would have to be rewritten to read any of them.
public struct ActivityMetadata: Hashable, Sendable {
    public var buttonURLs: [URL]

    public init(buttonURLs: [URL] = []) {
        self.buttonURLs = buttonURLs
    }
}

struct ActivityMetadataDTO: Decodable, Sendable {
    var button_urls: [String]?
}

/// `GET /content-inventory/users/{id}/outbox`.
struct ContentOutboxDTO: Decodable, Sendable {
    var entries: [ContentEntryDTO]?
}

/// One inventory entry.
///
/// `content_type`, `author_type`, `participants` and `signature` are on the wire
/// and are not decoded. The first is redundant with `extra.type` — see
/// `RecentActivity.Subject` — and the other three are for a feed this client
/// does not draw: a signature proves the entry to a *server*, and nothing here
/// forwards one.
struct ContentEntryDTO: Decodable, Sendable {
    var id: String?
    var author_id: UserID?
    var traits: [TraitDTO]?
    var extra: ExtraDTO?
    var started_at: Date?
    var ended_at: Date?
    var expires_at: Date?

    /// A trait is a tagged union whose tag is an integer and whose payload is
    /// one further key. Every field is optional because exactly one of them is
    /// present per object.
    struct TraitDTO: Decodable, Sendable {
        var type: Int?
        var first_time: Bool?
        var duration_seconds: Double?
        var is_live: Bool?
        var marathon: Bool?
        var streak_count_days: Int?
        var trending: Int?

        /// Nil for a type this client has never seen. Ten of the twelve appear
        /// in the capture and four of those are counts on a music entry that
        /// the row does not print; what is left is the six chips.
        var domain: RecentActivity.Trait? {
            switch type {
            case 1: first_time == true ? .newPlayer : nil
            case 2: duration_seconds.map { RecentActivity.Trait.duration($0) }
            case 3: is_live == true ? .live : nil
            case 6: marathon == true ? .marathon : nil
            case 8: streak_count_days.map { RecentActivity.Trait.streak(days: $0) }
            case 9: (trending ?? 0) > 0 ? .trending : nil
            default: nil
            }
        }
    }

    struct ExtraDTO: Decodable, Sendable {
        var type: String?
        var game_name: String?
        var activity_name: String?
        var application_id: ApplicationID?
        var artist: ArtistDTO?
        var media: MediaDTO?

        struct ArtistDTO: Decodable, Sendable {
            var name: String?
        }

        struct MediaDTO: Decodable, Sendable {
            var title: String?
            var image_url: String?
        }
    }

    var domain: RecentActivity? {
        guard let id, let authorID = author_id, let subject = extra?.domain else { return nil }
        return RecentActivity(
            id: id,
            authorID: authorID,
            subject: subject,
            traits: (traits ?? []).compactMap(\.domain),
            startedAt: started_at,
            endedAt: ended_at,
            expiresAt: expires_at
        )
    }
}

extension ContentEntryDTO.ExtraDTO {
    var domain: RecentActivity.Subject? {
        switch type {
        case "played_game_extra":
            guard let name = game_name, !name.isEmpty else { return nil }
            return .game(name: name, applicationID: application_id)
        case "launched_activity_extra":
            guard let name = activity_name, !name.isEmpty else { return nil }
            return .activity(name: name, applicationID: application_id)
        case "top_artist_extra":
            // The artist is the entry's subject and the nested media is the one
            // track named for it. A row with neither is dropped: "somebody
            // listened to something" is not worth a row.
            guard let track = media?.title ?? artist?.name, !track.isEmpty else { return nil }
            return .listening(
                track: track,
                artist: media?.title == nil ? nil : artist?.name,
                artworkURL: media?.image_url.flatMap(URL.init(string:))
            )
        default:
            return nil
        }
    }
}
