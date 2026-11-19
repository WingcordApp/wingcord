import Foundation
import SwiftUI
import WingcordCore

/// The discovery page, while it is open.
///
/// **One value for both halves.** Servers and apps are two different id spaces
/// over two different route families, and holding them as two states would mean
/// two answers to "what is this page showing" — which is how a tab switch ends
/// up drawing one half's spinner over the other half's grid.
struct DiscoveryState: Hashable, Sendable {

    /// Which half is showing.
    ///
    /// **Two segments, which is what makes a segmented control the right
    /// instrument** — §1's rule is `NSSegmentedControl` with `role: .tabs`, and
    /// it is what Clock and Podcasts use for exactly this. Categories are *not*
    /// a second segmented control: there are seventeen primary server headings
    /// and the control packs its segments to equal widths, so seventeen of them
    /// is a strip of unreadable slivers.
    enum Tab: String, CaseIterable, Hashable, Sendable {
        case servers
        case apps
        /// Only while Discord's `2026-10-game-discovery` or the reader's
        /// preview says so — see `AppModel.offersGamesDiscovery`.
        case games

        var title: String {
            switch self {
            case .servers: "Servers"
            case .apps: "Apps"
            case .games: "Games"
            }
        }
    }

    var tab: Tab = .servers
    /// What is typed. Empty is the browse state, which is a different question
    /// from "a search that found nothing".
    var query = ""

    // MARK: Servers

    /// The heading being browsed, or nil for the front page.
    ///
    /// **Nil is not "All".** The front page is the verified-and-partnered
    /// shortlist the browse route answers with no `categories` — six thousand
    /// official servers — and it is a genuinely different list from any category,
    /// not a union of them. Labelling it "All" would promise the whole of
    /// discovery, which that route does not answer.
    var categoryID: Int?
    /// The language a search is narrowed to, or nil for every language.
    ///
    /// **Search only, because that is the only route captured taking it.**
    /// `language_code` goes to `/discoverable-guilds/search`; the browse route
    /// was never seen with one, and offering a filter on a route that may
    /// ignore it is a control that changes nothing.
    var languageCode: String?
    var page: DiscoveryPage = .empty
    /// The per-category counts, and the query text they belong to.
    ///
    /// **Kept on the state rather than on the page, because it outlives it.**
    /// Captured: `with_counts=true` goes out once for a query and every
    /// refinement of that query — a bucket, a language — sends `false`. So the
    /// answer that carries the facet is replaced by answers that do not, and a
    /// facet read off the current page would empty itself the moment somebody
    /// used it.
    var facet: Facet?
    var isLoading = false
    var failure: String?

    /// One search's category counts.
    struct Facet: Hashable, Sendable {
        /// The query text these counts describe. A different one is a different
        /// facet, and that is the only thing that re-asks for it.
        var query: String
        /// Category id to count. The `-1` bucket is the total across all of
        /// them — `DiscoveryPage.allCategoriesFacet` — and it is what names the
        /// All row rather than a category that does not exist.
        var counts: [Int: Int]
    }

    // MARK: Apps

    /// The app whose own page is open, one level inside the Apps tab.
    ///
    /// **A stack of two, and the grid underneath is not thrown away.** Going
    /// back to it must not re-fetch a page somebody has already scrolled.
    var openAppID: ApplicationID?
    /// The app whose storefront is open, one level inside its page.
    ///
    /// **A third level, and the two under it are not thrown away.** The store is
    /// reached from an app's page and the page from the grid; going back twice
    /// must not re-fetch either.
    var openStoreID: ApplicationID?
    /// Which app heading is showing. **Featured by default, and never nil** —
    /// see `AppDirectoryCategory.featuredID`: no category at all is a different
    /// and much narrower search.
    var appCategoryID: Int? = AppDirectoryCategory.featuredID
    var apps: [ActivityApp] = []
    var appPage = 1
    var appPageCount = 1
    var isLoadingApps = false
    var appFailure: String?

    /// The load this grid came from, minted per fetch.
    ///
    /// **Discord's own, and it travels to the lurk.** Every captured discovery
    /// preview sends `recommendation_load_id` alongside `location=Guild
    /// Discovery`, which is how the click is tied back to the grid that offered
    /// it. Minted here rather than at the click, because the id identifies the
    /// *load* and a fresh one per card would say every card came from its own.
    var loadID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()

    /// Whether anything is in flight for the half on screen.
    var isBusy: Bool { tab == .servers ? isLoading : isLoadingApps }

    /// What the request that fills this page is keyed on.
    ///
    /// A value rather than three comparisons at each call site: the controller
    /// checks an answer against it before writing, and "did the question change
    /// while this was out" has to be one question.
    var serverRequest: ServerRequest {
        ServerRequest(
            query: query.trimmingCharacters(in: .whitespaces),
            categoryID: categoryID,
            languageCode: languageCode
        )
    }

    struct ServerRequest: Hashable, Sendable {
        var query: String
        var categoryID: Int?
        var languageCode: String?
        /// Whether this goes to the search route rather than the browse route.
        var isSearch: Bool { !query.isEmpty }
    }

    /// Whether this request has to ask for the facet.
    ///
    /// **Once per query text, and never for a refinement of it** — which is
    /// exactly what the two captures show the reference client doing, and what
    /// keeps a second round trip off every bucket press.
    func wantsFacet(for request: ServerRequest) -> Bool {
        request.isSearch && facet?.query != request.query
    }

    var appRequest: AppRequest {
        AppRequest(
            query: query.trimmingCharacters(in: .whitespaces),
            categoryID: appCategoryID,
            page: appPage
        )
    }

    struct AppRequest: Hashable, Sendable {
        var query: String
        var categoryID: Int?
        var page: Int
    }
}

/// One card in the servers grid.
///
/// A projection rather than the wire value: the card draws a CDN URL per hash
/// and a rosette per feature set, and resolving those in a view body would
/// resolve them on every scroll.
struct DiscoveryCard: Hashable, Sendable, Identifiable {
    var id: GuildID
    var name: String
    var description: String?
    /// The wide artwork across the head of the card.
    var artworkURL: URL?
    var iconURL: URL?
    var monogram: String
    var mark: GuildMark?
    var memberCount: Int
    var onlineCount: Int
    /// Whether this server can be looked at before joining. A card that cannot
    /// preview still joins — it simply has no way to be read first.
    var canPreview: Bool
    /// Whether the account is already in it, so the card says "Joined" rather
    /// than offering to join a server the reader is standing in.
    var isJoined: Bool
}

/// One app in the directory grid.
///
/// A projection for the reason `DiscoveryCard` is one — every URL on it is
/// resolved from a hash or an asset id, and resolving those in a view body
/// resolves them again on every scroll. Two extra facts over the launcher's
/// `ActivityRow`, and both are pictures: the banner across the card's head and
/// the loop that replaces it under the pointer.
struct DiscoveryAppCard: Hashable, Sendable, Identifiable {
    var id: ApplicationID
    var name: String
    var subtitle: String
    var isVerified: Bool
    /// The directory's own heading for it — "Moderation and Tools". **The line
    /// Discord draws between the name and the description**, and empty for an
    /// app the route filed under nothing.
    var category: String?
    /// How many servers have added it. Nil where the route did not say.
    var guildCount: Int?
    /// The still across the head of the card. Nil is a real state — see
    /// `AppModel.appBannerURL` — and the card falls back to the accent below.
    var bannerURL: URL?
    /// The bot's own profile accent, for an app with no banner. Discord draws a
    /// flat field of it rather than a hole; nil where the bot set none, and then
    /// the card's own raised ground stands.
    var accentColor: Color?
    /// The preview loop, for the cards that have one. **Only the hovered card
    /// ever builds a player**: see `DiscoveryAppTile`.
    var videoURL: URL?
    /// The banner's animated rendition, for an app whose bot banner is an `a_`
    /// asset and which has no preview loop.
    ///
    /// **The same URL `bannerURL` already holds**, because an animated hash
    /// resolves to `.gif` and `RemoteImage` draws its first frame — the still
    /// underneath and the film over it are one asset, which is the arrangement
    /// the sidebar's own banner uses. Nil where the still is anything else, and
    /// nil where there is a video: Discord's component passes
    /// `animatedUrl: undefined` down the video branch, so the two hover motions
    /// are never both offered.
    var animatedBannerURL: URL?
    /// The launcher's own row projection, so the icon and the monogram are
    /// resolved once for every surface that draws an app.
    var row: ActivityRow
    /// The icon's hash, for the one caller that needs a *different* rendition
    /// of it than the mark: the palette's 128-pixel WebP. See
    /// `AppIconGradientStore`.
    var iconHash: String?
}

/// One row of the Show menu: a heading, how many of the query's results are
/// filed under it, and nil for the All row that clears the filter.
struct DiscoveryFacetBucket: Hashable, Sendable, Identifiable {
    /// Nil is All — the `-1` bucket, which is a total rather than a category.
    var id: Int?
    var name: String
    var count: Int
}
