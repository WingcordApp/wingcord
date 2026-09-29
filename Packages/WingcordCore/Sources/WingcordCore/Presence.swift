import CoreGraphics
import Foundation

/// A person's availability.
public enum PresenceStatus: String, Hashable, Sendable, Codable, CaseIterable {
    case online
    case idle
    case doNotDisturb = "dnd"
    case invisible
    case offline

    /// What the roster sorts and groups by. Invisible is only ever *your own*
    /// status — everyone else's invisible arrives as offline — and it groups
    /// with online because that is where you are.
    public var isOnline: Bool {
        self != .offline
    }

    public var label: String {
        switch self {
        case .online: "Online"
        case .idle: "Idle"
        case .doNotDisturb: "Do Not Disturb"
        case .invisible: "Invisible"
        case .offline: "Offline"
        }
    }

    /// What picking this one actually does, where it is not obvious.
    ///
    /// Discord writes a line under two of the four and leaves the other two
    /// bare, which is the right split: Online and Idle mean what they say, and
    /// the two that change behaviour say how.
    public var explanation: String? {
        switch self {
        case .doNotDisturb: "You will not receive desktop notifications"
        case .invisible: "You will appear offline"
        default: nil
        }
    }

    /// The four a person can choose.
    ///
    /// **`.offline` is not one of them.** It is what *other* people are —
    /// everyone else's invisible arrives as offline — and choosing it is what
    /// `.invisible` means. A picker offering both would offer one state twice
    /// and a state nobody can be in.
    public static let choosable: [PresenceStatus] = [
        .online, .idle, .doNotDisturb, .invisible,
    ]
}

/// One person's presence, as the gateway last reported it.
///
/// Small and copied often — one per visible roster row, replaced on every
/// presence flush — so the activity list is behind an optional box on the same
/// argument as `MessagePayload`. Most people online are not doing anything the
/// client can show.
public struct Presence: Hashable, Sendable {
    public var userID: UserID
    public var status: PresenceStatus
    /// Whether any of the person's sessions is a phone. Drawn as the phone glyph
    /// instead of a dot.
    public var isOnMobile: Bool
    public var activities: PresenceActivities?

    public init(
        userID: UserID,
        status: PresenceStatus,
        isOnMobile: Bool = false,
        activities: PresenceActivities? = nil
    ) {
        self.userID = userID
        self.status = status
        self.isOnMobile = isOnMobile
        self.activities = activities
    }

    /// The custom status line, if the person has set one.
    public var customStatus: Activity? {
        activities?.list.first { $0.kind == .custom }
    }

    /// The activity worth showing on its own: the first in Discord's order that
    /// is not a custom status — Competing, then Streaming, then Playing, then
    /// the rest (`ActivityOrder`). A person can be playing a game *and* have a
    /// custom status, and the game is the activity.
    ///
    /// `.unknown` is Discord's hang status, which no surface lists.
    public var primaryActivity: Activity? {
        activities?.list.first { $0.kind != .custom && $0.kind != .unknown }
    }

    /// Everything a profile draws a card for, in Discord's order — every
    /// activity that is not a custom status, each application once (module
    /// `343129`). `primaryActivity` is the first of them.
    public var liveActivities: [Activity] {
        var cards: [Activity] = []
        for activity in activities?.list ?? [] where activity.kind != .custom && activity.kind != .unknown {
            guard !cards.contains(where: { $0.isSameSource(as: activity) }) else { continue }
            cards.append(activity)
        }
        return cards
    }
}

/// The activity list, boxed.
public final class PresenceActivities: Hashable, Sendable {
    /// **In Discord's order, and with Discord's one Playing** — see
    /// `ActivityOrder`. Every surface reads this list and none of them sorts
    /// it, so the order is decided once, here, where a presence is made.
    public let list: [Activity]
    public init(list: [Activity]) { self.list = ActivityOrder.presented(list) }

    public static func == (lhs: PresenceActivities, rhs: PresenceActivities) -> Bool {
        lhs === rhs || lhs.list == rhs.list
    }

    public func hash(into hasher: inout Hasher) { hasher.combine(list) }
}

public struct Activity: Hashable, Sendable {
    public enum Kind: Int, Hashable, Sendable {
        case playing = 0
        case streaming = 1
        case listening = 2
        case watching = 3
        case custom = 4
        case competing = 5
        case unknown = -1

        public init(rawValue: Int) {
            self = switch rawValue {
            case 0: .playing
            case 1: .streaming
            case 2: .listening
            case 3: .watching
            case 4: .custom
            case 5: .competing
            default: .unknown
            }
        }
    }

    public var kind: Kind
    public var name: String
    public var state: String?
    public var details: String?
    public var applicationID: ApplicationID?
    public var largeImageKey: String?
    public var smallImageKey: String?
    /// The hover texts on those two images.
    ///
    /// **The small image is a badge with no room for a caption**, so its text is
    /// the only thing that ever says what it means — Medal's small mark is the
    /// Medal logo and `small_text` is what names it.
    public var largeText: String?
    public var smallText: String?
    /// Where a click on each image goes, when the app published one.
    ///
    /// Captured from a live Medal presence: `large_url` is
    /// `medal.tv/games/counter-strike-2?ref=discordrpc` and `small_url` is
    /// `medal.tv/?ref=discordrpc` — see `RichPresenceTests`.
    public var largeImageURL: URL?
    public var smallImageURL: URL?
    /// A custom status' emoji.
    public var emoji: EmojiRef?
    public var startedAt: Date?
    /// When it will finish, for an activity that knows — a track's length, a
    /// match's clock. **Not a duration**: Discord sends an absolute instant, and
    /// what a client draws is the gap between the two ends.
    public var endsAt: Date?
    /// `[current, maximum]`. **This is where "1 Playing" comes from** on an
    /// activity invitation, and it is the only count on the wire — an app that
    /// sends no party is one this client cannot count for.
    public var partySize: [Int]?
    /// The session the activity belongs to.
    ///
    /// **Carried because it is half of an address, not because anything draws
    /// it.** The button URLs live behind
    /// `/users/{id}/sessions/{session_id}/activities/{application_id}/metadata`
    /// and there is no other way to reach them — a presence over the gateway
    /// sends the button *labels* and never their links.
    public var sessionID: String?
    /// The labels of the custom buttons, at most two.
    ///
    /// **Labels only.** Their URLs are the metadata route above; a button drawn
    /// from this array alone is a control that opens nothing, which is the inert
    /// control `INVARIANTS.md` §5.5 forbids.
    public var buttons: [String]
    /// When the app first published this activity.
    ///
    /// **The last tie-break in Discord's order** — see `ActivityOrder`. Nil
    /// sorts as the oldest, as Discord's `created_at ?? 0` does.
    public var createdAt: Date?
    /// An Activity launched in a voice channel — Discord's `EMBEDDED` flag
    /// (256). It changes the icon a one-line summary draws and the words it
    /// says.
    public var isEmbedded: Bool
    /// Which of its lines the app asked to be named by in a one-line summary.
    public var statusDisplay: StatusDisplay?
    /// The party's id.
    ///
    /// **Read only to recognise Spotify**, whose parties are `spotify:<id>` —
    /// Discord's own test (module `90644`), because a listening activity named
    /// "Spotify" alone is something any app can publish.
    public var partyID: String?
    /// Whether the app sent join or spectate secrets. Only their presence is
    /// kept: Discord counts them when it decides whether an activity is a rich
    /// presence at all.
    public var hasSecrets: Bool
    /// Where it is running — `"xbox"`, `"ps5"`, `"desktop"`. Read for the
    /// card's "Playing on Xbox".
    public var platform: String?
    /// Where the details line and the state line link to, when the app said.
    public var detailsURL: URL?
    public var stateURL: URL?
    /// What a listener would play along with — for a Spotify session, the
    /// track's id.
    public var syncID: String?
    /// Discord's `PLAY` and `SYNC` activity flags: whether the session offers
    /// "Play on Spotify" and "Listen Along" (module `402857`).
    public var offersPlay: Bool
    public var offersSync: Bool

    public static let syncFlag = 1 << 4
    public static let playFlag = 1 << 5

    /// The track a Spotify session is on, as the page Spotify opens — or nil
    /// for anything that is not one. A Spotify presence's party is
    /// `spotify:<user>`, which is how Discord tells it from any other music.
    public var spotifyTrackURL: URL? {
        guard partyID?.hasPrefix("spotify:") == true, let syncID, !syncID.isEmpty,
              let encoded = syncID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return nil }
        return URL(string: "https://open.spotify.com/track/\(encoded)")
    }

    /// `status_display_type`.
    public enum StatusDisplay: Int, Hashable, Sendable {
        case name = 0
        case state = 1
        case details = 2
    }

    public init(
        kind: Kind,
        name: String,
        state: String? = nil,
        details: String? = nil,
        applicationID: ApplicationID? = nil,
        largeImageKey: String? = nil,
        smallImageKey: String? = nil,
        largeText: String? = nil,
        smallText: String? = nil,
        largeImageURL: URL? = nil,
        smallImageURL: URL? = nil,
        emoji: EmojiRef? = nil,
        startedAt: Date? = nil,
        endsAt: Date? = nil,
        partySize: [Int]? = nil,
        sessionID: String? = nil,
        buttons: [String] = [],
        createdAt: Date? = nil,
        isEmbedded: Bool = false,
        statusDisplay: StatusDisplay? = nil,
        partyID: String? = nil,
        hasSecrets: Bool = false,
        platform: String? = nil,
        detailsURL: URL? = nil,
        stateURL: URL? = nil,
        syncID: String? = nil,
        offersPlay: Bool = false,
        offersSync: Bool = false
    ) {
        self.syncID = syncID
        self.offersPlay = offersPlay
        self.offersSync = offersSync
        self.platform = platform
        self.detailsURL = detailsURL
        self.stateURL = stateURL
        self.createdAt = createdAt
        self.isEmbedded = isEmbedded
        self.statusDisplay = statusDisplay
        self.partyID = partyID
        self.hasSecrets = hasSecrets
        self.partySize = partySize
        self.kind = kind
        self.name = name
        self.state = state
        self.details = details
        self.applicationID = applicationID
        self.largeImageKey = largeImageKey
        self.smallImageKey = smallImageKey
        self.largeText = largeText
        self.smallText = smallText
        self.largeImageURL = largeImageURL
        self.smallImageURL = smallImageURL
        self.emoji = emoji
        self.startedAt = startedAt
        self.endsAt = endsAt
        self.sessionID = sessionID
        self.buttons = buttons
    }

    /// The large artwork, at `side` points.
    public func largeArtworkURL(side: CGFloat) -> URL? {
        Self.assetURL(largeImageKey, application: applicationID, side: side)
    }

    /// The small badge that rides its corner.
    public func smallArtworkURL(side: CGFloat) -> URL? {
        Self.assetURL(smallImageKey, application: applicationID, side: side)
    }

    /// Resolves one asset key.
    ///
    /// **An asset key is a tagged union written as a string**, and only the
    /// untagged form is an application asset. The prefixes and their templates
    /// are Discord's own, from the presence documentation:
    ///
    /// | key | resolves to |
    /// | --- | --- |
    /// | `mp:{id}` | `media.discordapp.net/{id}` |
    /// | `spotify:{id}` | `i.scdn.co/image/{id}` |
    /// | `twitch:{name}` | a live preview still |
    /// | `youtube:{id}` | a video thumbnail |
    /// | anything else | `/app-assets/{application}/{key}.png` |
    ///
    /// A key this client does not recognise resolves to nil rather than being
    /// pasted onto the application path, because the failure modes differ: a nil
    /// draws the placeholder the caller already has, and a wrong path draws a
    /// permanent grey box that looks like a broken picture.
    public static func assetURL(
        _ key: String?,
        application: ApplicationID?,
        side: CGFloat
    ) -> URL? {
        guard let key, !key.isEmpty else { return nil }
        guard let separator = key.firstIndex(of: ":") else {
            guard let application else { return nil }
            return CDN.applicationAsset(id: application, assetID: key, side: side)
        }
        let value = String(key[key.index(after: separator)...])
        guard !value.isEmpty else { return nil }
        switch key[key.startIndex..<separator] {
        case "mp":
            return URL(string: "https://media.discordapp.net/\(value)")
        case "spotify":
            return URL(string: "https://i.scdn.co/image/\(value)")
        case "twitch":
            let pixels = CDN.rung(forSide: side)
            return URL(
                string: "https://static-cdn.jtvnw.net/previews-ttv"
                    + "/live_user_\(value)-\(pixels)x\(pixels).jpg"
            )
        case "youtube":
            return URL(string: "https://i.ytimg.com/vi/\(value)/hqdefault.jpg")
        default:
            // A prefix this client has never seen is not an application asset,
            // and pasting it onto the application path draws a permanent grey
            // box that reads as a broken picture rather than as a missing one.
            return nil
        }
    }

    /// The single line a roster row shows beneath the name.
    ///
    /// A custom status is its own `state` and nothing else; every other kind
    /// gets a verb, because "Wingcord" alone under a name says nothing about
    /// whether the person is playing it, streaming it or listening to it.
    public var rowSubtitle: String? {
        switch kind {
        case .custom:
            state
        case .playing:
            "Playing \(name)"
        case .streaming:
            "Streaming \(name)"
        case .listening:
            state.map { "Listening to \($0)" } ?? "Listening to \(name)"
        case .watching:
            "Watching \(name)"
        case .competing:
            "Competing in \(name)"
        case .unknown:
            name.isEmpty ? nil : name
        }
    }
}
