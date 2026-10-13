import Foundation

// MARK: - Activities
//
// An activity is an application that runs *inside* the client — a web app the
// client frames and talks to over `postMessage`, not a bot and not a website.
// Discord calls the whole surface "Apps"; the launcher, the directory rows and
// the invitation card in a transcript are all views onto the one application
// object below.
//
// **Every shape here is a capture.** `activities123.har` and
// `activities_search.har` (2026-09-02) carry all thirty of the requests this
// file decodes, response bodies included, and `ActivityDecodeTests` replays
// them. Nothing here was read off documentation: the two routes the directory
// is built on — `/activities/shelf` and
// `/application-directory-static/collections` — are not documented anywhere.

/// An application that can be launched into a channel.
///
/// **`config` is what separates an activity from an ordinary app.** The
/// directory's search and its "Bot Games" collection both return applications
/// with no `embedded_activity_config` at all — those are bots, and they cannot
/// be launched. A row that offers Launch on one is the inert control
/// `INVARIANTS.md` §5.5 forbids, so the launcher gates on `isLaunchable`
/// rather than on which list the app arrived in.
public struct ActivityApp: Hashable, Sendable, Identifiable {
    public var id: ApplicationID
    public var name: String
    public var iconHash: String?
    /// The wide artwork on a featured tile.
    ///
    /// **The `embedded_cover` asset, not `cover_image`.** Both exist and they
    /// are different pictures; this is the one Discord actually draws. Checked
    /// by fetching both and looking at them: Farm Merge Valley has no
    /// `cover_image` at all yet draws a full artwork tile, and its
    /// `embedded_cover` **is** that tile. `cover_image` is present on 45 of the
    /// captured shelf's 73 apps where `embedded_cover` is present on all 73, so
    /// a client that prefers `cover_image` draws artwork for some rows and a
    /// blank for the rest.
    ///
    /// **Highest id wins when the name repeats.** Six apps register
    /// `embedded_cover` twice — the same name against two assets — and the
    /// newer upload is the live one. Farm Merge Valley is one of them.
    public var tileAssetID: String?
    /// **The application's own bot account banner, and the picture a directory
    /// card actually draws.**
    ///
    /// Not an application asset at all: it is the *user* banner of the bot the
    /// application ships, at `/banners/{id}/{hash}`. It is on **180 of the 265**
    /// apps in `discoverableapps.har` where `cover_image` is on 75 and a
    /// carousel still on 100, and it is the one Discord's own grid draws — Farm
    /// Merge Valley's promo card, FlaviBot's purple artwork, `.fmbot`'s blue
    /// one. A client that reached for `cover_image` first drew a banner for a
    /// quarter of the directory and an empty band for the rest, which is what
    /// this was.
    public var botBannerHash: String?
    /// The colour the bot's profile falls back to, for the apps with no banner
    /// at all. Discord draws a flat field of it rather than a hole.
    public var botAccentColor: Int?
    /// The wide artwork Discord *also* keeps, and does not use here.
    ///
    /// Kept because it is the one asset on this type reachable without the
    /// shelf's `assets` map — search results and `/applications/public` both
    /// carry it — so it is the fallback when a row was never in the shelf.
    /// Served from `/app-icons/{id}/`, not `/app-assets/`: probed, and
    /// `/app-assets/{id}/store/{hash}.png` 404s.
    public var coverHash: String?
    /// The first still or loop from the directory's carousel — the picture at
    /// the top of the detail page. Already a `proxy_url`, so the request goes
    /// to Discord rather than to `app-directory-assets.discordactivities.com`.
    public var heroImageURL: URL?
    /// The one-line subtitle a directory row draws. Discord writes a shorter
    /// line for this than the full description and they are not always the
    /// same sentence; nil when the route did not carry a directory entry.
    public var tagline: String?
    /// How many servers have added the app. Only the directory routes carry it.
    public var guildCount: Int?
    public var summary: String
    public var isVerified: Bool
    /// Discord's own copy, unedited. The directory rows and the detail page
    /// both draw it; the rows clamp to one line and the page does not.
    public var about: String
    /// The developer's long-form copy, in Markdown.
    ///
    /// **A different field from `about` and a much longer one** —
    /// `directory_entry.detailed_description`, on 269 of the captured 343. It is
    /// what Discord's page draws under "Overview", bullets, bold and inline code
    /// and all, where `description` is the one-paragraph summary a card shows.
    public var detailedDescription: String?
    /// The permissions the app asks for on a server install, from
    /// `install_params.permissions`. Drawn as the "Required Permissions" list.
    public var installPermissions: Permissions?
    /// The application's own flags, which is where the privileged gateway
    /// intents live — see `dataAccess`.
    public var flags: UInt64 = 0
    /// Whether the app sells anything. Discord draws "In-App Purchases" under
    /// the name for one that does.
    public var isMonetized = false
    /// The app's support server, when it names one. Discord draws it as a card.
    public var supportGuild: AppSupportGuild?
    /// The five commands Discord lists under "Popular Slash Commands", in the
    /// route's own order — `directory_entry.popular_application_commands`,
    /// decoded and then thrown away for two releases.
    public var popularCommands: [ApplicationCommand] = []
    /// Discord's own headings for the app, in its order — `[{"id": 8, "name":
    /// "Moderation and Tools"}, {"id": 9, "name": "Social"}]` for FlaviBot.
    ///
    /// **Not `tags`, which are the developer's free text.** These are the app
    /// directory's own five headings and they are the line Discord draws under
    /// an app's name on a card. Named by the route, so another language gets its
    /// own; the ids are `AppDirectoryCategory`'s space.
    public var categoryNames: [String] = []
    /// The developer's own words for what kind of thing this is — "Video
    /// Player", "Watch". Free text, two to five of them, drawn as chips.
    public var tags: [String]
    /// How many people fit. **`-1` is unlimited and `nil` is unstated** — three
    /// apps in the captured shelf say `-1`, thirty-seven say nothing at all,
    /// and the rest name a number from 1 to 1000. A client that reads the
    /// absent case as zero draws "0 players" on half the directory.
    public var maxParticipants: Int?
    public var termsOfServiceURL: URL?
    public var privacyPolicyURL: URL?
    /// The developer's own links, beside the two Discord requires.
    ///
    /// **Named by the developer, so they cannot be a fixed set** — Blazing 8s
    /// carries one called `FAQ` and the Resident Evil experience carries none.
    /// A row per entry, drawn from what arrived.
    public var externalLinks: [ExternalLink] = []
    /// The locales this app says it speaks, as BCP-47 tags. Discord's page draws
    /// them under "Supported Languages" and draws the *localised name* rather
    /// than the tag — `English, US` for `en-US`.
    public var supportedLocales: [String] = []
    /// Every picture on the app's own page, in the developer's order.
    ///
    /// **The whole strip, where this used to keep only the first.** `heroImageURL`
    /// is that first item and stays what the banner draws; the rest are the
    /// gallery Discord pages under the title, and dropping them was decoding a
    /// list and using one of it.
    public var gallery: [URL] = []
    /// Present only on applications that actually embed. See the type note.
    public var config: EmbeddedActivityConfig?

    public init(
        id: ApplicationID,
        name: String,
        iconHash: String? = nil,
        tileAssetID: String? = nil,
        coverHash: String? = nil,
        botBannerHash: String? = nil,
        botAccentColor: Int? = nil,
        categoryNames: [String] = [],
        detailedDescription: String? = nil,
        installPermissions: Permissions? = nil,
        flags: UInt64 = 0,
        isMonetized: Bool = false,
        supportGuild: AppSupportGuild? = nil,
        popularCommands: [ApplicationCommand] = [],
        heroImageURL: URL? = nil,
        tagline: String? = nil,
        guildCount: Int? = nil,
        summary: String = "",
        isVerified: Bool = false,
        about: String = "",
        tags: [String] = [],
        maxParticipants: Int? = nil,
        termsOfServiceURL: URL? = nil,
        privacyPolicyURL: URL? = nil,
        config: EmbeddedActivityConfig? = nil
    ) {
        self.id = id
        self.name = name
        self.iconHash = iconHash
        self.tileAssetID = tileAssetID
        self.coverHash = coverHash
        self.botBannerHash = botBannerHash
        self.botAccentColor = botAccentColor
        self.categoryNames = categoryNames
        self.detailedDescription = detailedDescription
        self.installPermissions = installPermissions
        self.flags = flags
        self.isMonetized = isMonetized
        self.supportGuild = supportGuild
        self.popularCommands = popularCommands
        self.heroImageURL = heroImageURL
        self.tagline = tagline
        self.guildCount = guildCount
        self.summary = summary
        self.isVerified = isVerified
        self.about = about
        self.tags = tags
        self.maxParticipants = maxParticipants
        self.termsOfServiceURL = termsOfServiceURL
        self.privacyPolicyURL = privacyPolicyURL
        self.config = config
    }

    /// Whether this app can be launched into a channel at all.
    ///
    /// Two conditions, and both are load-bearing. An application with no
    /// embedded config is a bot. One whose config does not list `web` runs
    /// only inside Discord's own mobile shells — five apps in the captured
    /// shelf are `["web"]`, one is `["android", "web"]`, and none is
    /// mobile-only, but the field exists precisely so that can change.
    public var isLaunchable: Bool {
        config?.supportsWeb ?? false
    }

    /// The participant chip's text, or nil when the app states no limit.
    ///
    /// Nil rather than "Unknown": a chip that says nothing useful is a chip
    /// that costs a row of space to say so.
    public var participantsLabel: String? {
        guard let maxParticipants else { return nil }
        if maxParticipants < 0 { return "Unlimited" }
        guard maxParticipants > 0 else { return nil }
        return maxParticipants == 1 ? "1 player" : "\(maxParticipants) players"
    }

    /// The languages this app speaks, named rather than tagged.
    ///
    /// `en-US` is a tag and "English, US" is what a person reads; Discord draws
    /// the second and so does this. An unrecognised tag is shown as itself
    /// rather than dropped — it is still a true answer.
    public var languageNames: [String] {
        supportedLocales.map { tag in
            Locale.current.localizedString(forIdentifier: tag)
                ?? Locale.current.localizedString(forLanguageCode: tag)
                ?? tag
        }
    }

    /// The line under the name in a directory row: the directory's own short
    /// description where there is one, and the full description otherwise.
    public var rowSubtitle: String {
        if let tagline, !tagline.isEmpty { return tagline }
        return about
    }
}

// MARK: - What an app can read

/// One privileged gateway intent, in the words Discord's own page uses.
///
/// **Three of them, and each is two bits.** Discord splits every privileged
/// intent into an *approved* flag and a `_LIMITED` one for an app under the
/// hundred-server threshold; both mean the app has it, so both are read. Checked
/// against two captures: `.fmbot`'s `10797056` has bits 14, 15 and 18 and its
/// page lists **Members** and **Read Messages**; OwO's `10747904` has bit 18
/// alone and its page lists **Read Messages** and nothing else.
public struct AppDataAccess: Hashable, Sendable, Identifiable {
    public var id: String { title }
    public var title: String
    public var detail: String
    /// An SF Symbol for the row. Discord draws its own glyphs; these are the
    /// nearest system ones, so the list follows the reader's icon settings.
    public var symbolName: String

    /// What the flags say this app can read, in Discord's own order.
    public static func all(flags: UInt64) -> [AppDataAccess] {
        var access: [AppDataAccess] = []
        if flags & (presence | presenceLimited) != 0 {
            access.append(AppDataAccess(
                title: "Presence",
                detail: "Can see the status and activity of everyone in the server.",
                symbolName: "circle.circle.fill"
            ))
        }
        if flags & (guildMembers | guildMembersLimited) != 0 {
            access.append(AppDataAccess(
                title: "Members",
                detail: "Can see who's in the server and their roles, nicknames, "
                    + "and permission changes.",
                symbolName: "person.2.fill"
            ))
        }
        if flags & (messageContent | messageContentLimited) != 0 {
            access.append(AppDataAccess(
                title: "Read Messages",
                detail: "Can access messages in the server and read their contents.",
                symbolName: "bubble.left.fill"
            ))
        }
        // Discord's own ordering puts Read Messages first on both captured
        // pages, above Members. Reversed once rather than written backwards, so
        // the bit order above still reads as the wire's.
        return access.reversed()
    }

    static let presence: UInt64 = 1 << 12
    static let presenceLimited: UInt64 = 1 << 13
    static let guildMembers: UInt64 = 1 << 14
    static let guildMembersLimited: UInt64 = 1 << 15
    static let messageContent: UInt64 = 1 << 18
    static let messageContentLimited: UInt64 = 1 << 19
}

/// An app's support server, as its directory page describes it.
///
/// **The whole guild object arrives on the app's own route** — name, icon,
/// description, features and both counts — so the card needs no second fetch.
/// It is the one place in this app that draws a server the reader is not in and
/// has not searched for.
public struct AppSupportGuild: Hashable, Sendable, Identifiable {
    public var id: GuildID
    public var name: String
    public var iconHash: String?
    public var description: String?
    /// The wide artwork behind the card. `home_header` is the newer field and
    /// the one Discord draws; the splashes are the fallback.
    public var headerHash: String?
    public var splashHash: String?
    public var discoverySplashHash: String?
    public var memberCount: Int
    public var onlineCount: Int

    public init(
        id: GuildID,
        name: String,
        iconHash: String? = nil,
        description: String? = nil,
        headerHash: String? = nil,
        splashHash: String? = nil,
        discoverySplashHash: String? = nil,
        memberCount: Int = 0,
        onlineCount: Int = 0
    ) {
        self.id = id
        self.name = name
        self.iconHash = iconHash
        self.description = description
        self.headerHash = headerHash
        self.splashHash = splashHash
        self.discoverySplashHash = discoverySplashHash
        self.memberCount = memberCount
        self.onlineCount = onlineCount
    }

    public var monogram: String {
        let letters = name.split(separator: " ").compactMap(\.first).prefix(2)
        return letters.isEmpty ? "#" : String(letters).uppercased()
    }
}

/// One of the developer's own links on an app's directory page.
public struct ExternalLink: Hashable, Sendable, Identifiable {
    public var name: String
    public var url: URL

    public var id: URL { url }

    public init(name: String, url: URL) {
        self.name = name
        self.url = url
    }
}

/// What makes an application embeddable, and how it presents in the shelf.
public struct EmbeddedActivityConfig: Hashable, Sendable {
    /// The asset behind the looping preview on the detail page.
    ///
    /// **Not one of the ids in the shelf's `assets` map.** That map holds only
    /// `type: 1` — images — and this id is in none of them. It resolves at
    /// `/app-assets/{app}/store/{asset}.mp4`, probed live; the four other
    /// spellings tried first all 404'd. See `CDN.activityPreviewVideo`.
    public var previewVideoAssetID: String?
    /// `web`, `ios`, `android`. Only the first matters here.
    public var supportedPlatforms: [String]
    /// Where the app sorts in the shelf when nothing else orders it.
    public var shelfRank: Int?
    /// Whether the app gates on the reader's age before it will run.
    public var requiresAgeGate: Bool
    /// Whether the app talks to the network directly rather than through
    /// `{app_id}.discordsays.com/.proxy/…`. Read but not acted on: the runtime
    /// frames the app's own origin either way, and the proxy is the app's
    /// concern rather than the client's.
    public var hasCSPException: Bool
    /// Whether the app shows advertisements. Surfaced on the detail page,
    /// because it is the one thing in this config a reader would want to know
    /// before pressing Launch.
    public var displaysAdvertisements: Bool

    public init(
        previewVideoAssetID: String? = nil,
        supportedPlatforms: [String] = [],
        shelfRank: Int? = nil,
        requiresAgeGate: Bool = false,
        hasCSPException: Bool = false,
        displaysAdvertisements: Bool = false
    ) {
        self.previewVideoAssetID = previewVideoAssetID
        self.supportedPlatforms = supportedPlatforms
        self.shelfRank = shelfRank
        self.requiresAgeGate = requiresAgeGate
        self.hasCSPException = hasCSPException
        self.displaysAdvertisements = displaysAdvertisements
    }

    public var supportsWeb: Bool { supportedPlatforms.contains("web") }
}

// MARK: - The directory

/// One titled row in the launcher — "Promoted", "Puzzle Games", "Bot Games".
///
/// **`position` is the order, and it is not the order the route returns them
/// in.** The captured response arrives Puzzle, Social, Card, Merge, Strategy,
/// Chill, Action, Promoted, Bot; sorted by `position` it is Promoted, Puzzle,
/// Card, Strategy, Chill, Social, Merge, Action, Bot — which is the order the
/// reference client draws, top to bottom. A client that trusts array order
/// puts Promoted eighth.
public struct ActivityCollection: Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var position: Int
    /// `5` is the two-across artwork row Discord calls Promoted; `4` is a list
    /// of rows. Kept as the raw value rather than a two-case enum because a
    /// third layout would otherwise decode as one of these two and draw wrong.
    public var kind: Int
    public var apps: [ActivityApp]

    public init(id: String, title: String, position: Int, kind: Int, apps: [ActivityApp]) {
        self.id = id
        self.title = title
        self.position = position
        self.kind = kind
        self.apps = apps
    }

    /// Whether this row draws as artwork tiles rather than as a list.
    public var isFeatured: Bool { kind == 5 }
}

/// Everything the launcher needs for its first paint.
public struct ActivityDirectory: Hashable, Sendable {
    /// Ordered by `position`, already.
    public var collections: [ActivityCollection]
    /// Every launchable app the shelf knows, by id — the pool the Recents
    /// row and the invitation card resolve names and artwork against.
    public var apps: [ApplicationID: ActivityApp]
    /// The shelf's own order — Discord's ranking, which a call's Suggested
    /// Activities read from the top of.
    public var shelf: [ApplicationID]

    public init(
        collections: [ActivityCollection] = [],
        apps: [ApplicationID: ActivityApp] = [:],
        shelf: [ApplicationID] = []
    ) {
        self.collections = collections
        self.apps = apps
        self.shelf = shelf
    }

    public var isEmpty: Bool { collections.isEmpty && apps.isEmpty }
}

// MARK: - An instance

/// Where an activity is running.
///
/// The wire calls this a *location id* and spells it `pc-{channel}` for a
/// private channel or `gc-{guild}-{channel}` for one in a server. It is a path
/// segment on the join and leave routes and a query parameter on the frame's
/// own URL, so it is a value with a spelling rather than a pair of ids.
public struct ActivityLocation: Hashable, Sendable {
    public var guildID: GuildID?
    public var channelID: ChannelID

    public init(guildID: GuildID? = nil, channelID: ChannelID) {
        self.guildID = guildID
        self.channelID = channelID
    }

    /// `pc` for a DM or group DM, `gc` for a channel in a server.
    public var kind: String { guildID == nil ? "pc" : "gc" }

    public var rawValue: String {
        if let guildID {
            "gc-\(guildID.rawValue)-\(channelID.rawValue)"
        } else {
            "pc-\(channelID.rawValue)"
        }
    }

    public init?(rawValue: String) {
        let parts = rawValue.split(separator: "-", omittingEmptySubsequences: false)
        switch parts.count {
        case 2 where parts[0] == "pc":
            guard let channel = ChannelID(parts[1]) else { return nil }
            self.init(channelID: channel)
        case 3 where parts[0] == "gc":
            guard let guild = GuildID(parts[1]), let channel = ChannelID(parts[2]) else { return nil }
            self.init(guildID: guild, channelID: channel)
        default:
            return nil
        }
    }
}

/// A running activity, named the way every route that takes one names it.
///
/// The composite spelling is `i-{instance}-{location}` — captured as
/// `i-1544745440824660141-pc-1424759145021837325` on the invitation message,
/// against a leave route that took `pc-1424759145021837325` and
/// `1544745440824660141` as separate path segments. **The instance half is the
/// id of the interaction that created it**, which is how a client that sent
/// the launch can name the instance before any dispatch tells it one exists.
public struct ActivityInstanceID: Hashable, Sendable {
    /// The launching interaction's id.
    public var instance: String
    public var location: ActivityLocation

    public init(instance: String, location: ActivityLocation) {
        self.instance = instance
        self.location = location
    }

    public var rawValue: String { "i-\(instance)-\(location.rawValue)" }

    public init?(rawValue: String) {
        guard rawValue.hasPrefix("i-") else { return nil }
        let body = rawValue.dropFirst(2)
        guard let split = body.firstIndex(of: "-") else { return nil }
        let instance = String(body[body.startIndex..<split])
        guard !instance.isEmpty, instance.allSatisfy(\.isNumber) else { return nil }
        guard let location = ActivityLocation(rawValue: String(body[body.index(after: split)...]))
        else { return nil }
        self.init(instance: instance, location: location)
    }
}

// MARK: - The invitation in a transcript

/// What a launch leaves behind in the channel.
///
/// A `MessageKind.contextMenuCommand` message from the application's own
/// webhook, with **no content, no embeds and no components** — the captured
/// message is empty but for `application` and `activity_instance`. The whole
/// card a reader sees is drawn by the client out of those two, which is why
/// this type carries the artwork rather than pointing at an embed that does
/// not exist.
///
/// **The live state is deliberately absent.** Discord's own card counts a
/// running instance up ("00:16", "1 Playing") off the
/// `EMBEDDED_ACTIVITY_UPDATE_V2` dispatch — a gateway event named by
/// `docs.discord.food` but with no published payload, and not present in any
/// capture this app has. Rather than invent field names, the card draws the
/// resolved state the capture *does* show and `ActivityInvite` has nowhere to
/// put a participant count. See `HANDOFF.md`.
public struct ActivityInvite: Hashable, Sendable, Codable {
    public var applicationID: ApplicationID
    public var name: String
    public var iconHash: String?
    /// Nil when the launch was into a channel this client cannot name — the
    /// card still draws, it just cannot offer to rejoin.
    public var instanceID: String?

    public init(
        applicationID: ApplicationID,
        name: String,
        iconHash: String? = nil,
        instanceID: String? = nil
    ) {
        self.applicationID = applicationID
        self.name = name
        self.iconHash = iconHash
        self.instanceID = instanceID
    }

    public var instance: ActivityInstanceID? {
        instanceID.flatMap(ActivityInstanceID.init(rawValue:))
    }
}

// MARK: - What the routes answer with
//
// These live here rather than beside the routes that build them for the reason
// `AuthorizedApp` does: the UI reads them, and the UI does not import the
// network package. `WingcordNet` holds the DTOs; the domain values it decodes
// them into belong to whoever draws them.

/// One page of the launcher's search.
///
/// Seven results a page against a `result_count` in the hundreds, so paging is
/// the normal case rather than the edge.
public struct ActivitySearchPage: Hashable, Sendable {
    public var apps: [ActivityApp]
    public var page: Int
    public var pageCount: Int
    public var totalCount: Int

    public init(apps: [ActivityApp], page: Int, pageCount: Int, totalCount: Int) {
        self.apps = apps
        self.page = page
        self.pageCount = pageCount
        self.totalCount = totalCount
    }

    public var hasMore: Bool { page < pageCount }
}

/// The command that opens an activity.
///
/// An activity is launched by *invoking a command*, not by a launch route —
/// and the launch echoes this whole record back inside the interaction rather
/// than naming it, which is why it keeps fields nothing here ever reads.
public struct ActivityEntryPoint: Hashable, Sendable {
    public var id: String
    public var applicationID: ApplicationID
    public var version: String
    public var name: String
    public var contexts: [Int]
    public var integrationTypes: [Int]
    /// The developer's own one-liner. Echoed back inside the launch rather than
    /// drawn: see `summary`, `dmPermission` and `handler` below.
    public var summary: String
    /// **Three fields the launch echoes and this client used to invent.**
    ///
    /// `POST /interactions` repeats the whole command record inside
    /// `data.application_command`, and `launch activity.har` shows the reference
    /// client echoing the *index's* values verbatim — Wordle's `play` goes out
    /// with `handler: 1`, `dm_permission: true` and its real description. This
    /// client was sending `2`, `false` and an empty string on every launch,
    /// which is a shape nothing on the wire ever answered with.
    public var dmPermission: Bool
    /// `2` is Discord opening the activity itself, `1` is the application
    /// answering and opening it in its response. **Not a filter** — see
    /// `CommandIndex.entryPoint` — and not this client's to choose.
    public var handler: Int?

    public init(
        id: String,
        applicationID: ApplicationID,
        version: String,
        name: String,
        contexts: [Int],
        integrationTypes: [Int],
        summary: String = "",
        dmPermission: Bool = true,
        handler: Int? = nil
    ) {
        self.id = id
        self.applicationID = applicationID
        self.version = version
        self.name = name
        self.contexts = contexts
        self.integrationTypes = integrationTypes
        self.summary = summary
        self.dmPermission = dmPermission
        self.handler = handler
    }
}

/// What a consent sheet needs to ask its question.
public struct ActivityAuthorization: Hashable, Sendable {
    public var applicationID: ApplicationID
    public var name: String
    public var iconHash: String?
    public var isVerified: Bool
    public var scopes: [String]
    /// Whether this account has already granted these scopes. A client that
    /// ignores it puts a consent sheet in front of somebody who consented last
    /// week, every time they press Launch.
    public var isAlreadyAuthorized: Bool
    public var termsOfServiceURL: URL?
    public var privacyPolicyURL: URL?

    public init(
        applicationID: ApplicationID,
        name: String,
        iconHash: String? = nil,
        isVerified: Bool = false,
        scopes: [String] = [],
        isAlreadyAuthorized: Bool = false,
        termsOfServiceURL: URL? = nil,
        privacyPolicyURL: URL? = nil
    ) {
        self.applicationID = applicationID
        self.name = name
        self.iconHash = iconHash
        self.isVerified = isVerified
        self.scopes = scopes
        self.isAlreadyAuthorized = isAlreadyAuthorized
        self.termsOfServiceURL = termsOfServiceURL
        self.privacyPolicyURL = privacyPolicyURL
    }
}

// MARK: - What this client publishes as its own activity

/// A rich presence, as this client broadcasts one.
///
/// **Separate from `Activity`, which is what other people's presences decode
/// into.** They describe the same object on the wire and are deliberately not
/// the same type: the read side is lenient about everything (a field Discord
/// adds must not break a roster) where the write side has to produce exactly
/// what the gateway accepts, and one type doing both ends up lenient in the
/// place that matters.
///
/// **Every field here has been seen on a real activity.** `details`, `state`,
/// `assets` and `timestamps` come from the `SET_ACTIVITY` an embedded app sent
/// this client — captured in `session.log`, from Watch Together:
///
/// ```json
/// {"cmd":"SET_ACTIVITY","args":{"activity":{"type":3,"details":"Adding videos",
///  "assets":{"large_image":"servericon"},"party":{"id":"…"}}}}
/// ```
///
/// The link and button fields come from a live Medal presence: two buttons
/// ("Follow on Medal", "Download Medal"), a large image linking to
/// `medal.tv/games/counter-strike-2?ref=discordrpc` and a small one linking to
/// `medal.tv/?ref=discordrpc`.
public struct RichPresenceActivity: Hashable, Sendable {
    /// What the line reads as: 0 Playing, 1 Streaming, 2 Listening,
    /// 3 Watching, 5 Competing. **Not an enum**, because the value is echoed
    /// from whatever an app asked for and a type this client has no name for
    /// must still round-trip rather than becoming "Playing".
    public var type: Int
    public var name: String
    /// The first line under the name.
    public var details: String?
    /// The second. On an embedded activity this is often the party's state.
    public var state: String?
    public var assets: Assets?
    public var timestamps: Timestamps?
    public var party: Party?
    /// Button *labels*, at most two.
    ///
    /// **Labels only — the URLs are not on the presence.** A reader fetches
    /// them from
    /// `GET /users/{user}/sessions/{session}/activities/{application}/metadata`,
    /// which answers `{"button_urls":[…]}`. Captured against Medal, whose two
    /// buttons resolved to `medal.tv/u/Browhiskey` and `medal.tv/`.
    public var buttons: [String]
    public var applicationID: ApplicationID?
    /// What a listener plays to follow along — Spotify's track id. Nil on
    /// everything that is not something to play.
    public var syncID: String?
    /// Discord's activity flags: `PLAY | SYNC`, 48, on a Spotify session.
    public var flags: Int
    /// What following along needs beyond the track. Spotify's only.
    public var metadata: ListeningMetadata?
    /// A Streaming activity's stream (`url`).
    public var url: URL?
    /// Where the details line and the state line link to.
    public var detailsURL: URL?
    public var stateURL: URL?
    /// The buttons' links, in their labels' order — sent as
    /// `metadata.button_urls`, which is what a reader's metadata route
    /// answers with.
    public var buttonURLs: [URL] = []
    /// Which line names the activity in a member list — Discord's
    /// `status_display_type`: 0 the name, 1 the state, 2 the details. Nil
    /// where the app said nothing, which is the name.
    public var statusDisplayType: Int?

    /// Spotify's `metadata` on a Listening activity (`655116`'s `getActivity`).
    public struct ListeningMetadata: Hashable, Sendable {
        public var contextURI: String?
        public var albumID: String
        public var artistIDs: [String]
        /// `track` or `episode`.
        public var type: String

        public init(contextURI: String?, albumID: String, artistIDs: [String], type: String) {
            self.contextURI = contextURI
            self.albumID = albumID
            self.artistIDs = artistIDs
            self.type = type
        }
    }

    public struct Assets: Hashable, Sendable {
        /// An application asset id, or an `mp:`-prefixed external reference.
        public var largeImage: String?
        public var largeText: String?
        /// Where the large image goes when clicked.
        public var largeURL: URL?
        public var smallImage: String?
        public var smallText: String?
        public var smallURL: URL?

        public init(
            largeImage: String? = nil,
            largeText: String? = nil,
            largeURL: URL? = nil,
            smallImage: String? = nil,
            smallText: String? = nil,
            smallURL: URL? = nil
        ) {
            self.largeImage = largeImage
            self.largeText = largeText
            self.largeURL = largeURL
            self.smallImage = smallImage
            self.smallText = smallText
            self.smallURL = smallURL
        }
    }

    /// Milliseconds since the epoch, which is what the wire carries — **not
    /// seconds.** A client that sends seconds dates every activity to 1970 and
    /// every elapsed clock reads as decades.
    public struct Timestamps: Hashable, Sendable {
        public var start: Int?
        public var end: Int?

        public init(start: Int? = nil, end: Int? = nil) {
            self.start = start
            self.end = end
        }
    }

    /// `size` is `[current, maximum]`. This is where "1 Playing" comes from.
    public struct Party: Hashable, Sendable {
        public var id: String?
        public var size: [Int]?

        public init(id: String? = nil, size: [Int]? = nil) {
            self.id = id
            self.size = size
        }

        public var current: Int? { size?.first }
        public var maximum: Int? { size?.count ?? 0 > 1 ? size?[1] : nil }
    }

    public init(
        type: Int,
        name: String,
        details: String? = nil,
        state: String? = nil,
        assets: Assets? = nil,
        timestamps: Timestamps? = nil,
        party: Party? = nil,
        buttons: [String] = [],
        applicationID: ApplicationID? = nil,
        syncID: String? = nil,
        flags: Int = 0,
        metadata: ListeningMetadata? = nil
    ) {
        self.type = type
        self.name = name
        self.details = details
        self.state = state
        self.assets = assets
        self.timestamps = timestamps
        self.party = party
        self.buttons = buttons
        self.applicationID = applicationID
        self.syncID = syncID
        self.flags = flags
        self.metadata = metadata
    }
}
