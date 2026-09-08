import Foundation
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

        var title: String {
            switch self {
            case .servers: "Servers"
            case .apps: "Apps"
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
    var categories: [DiscoveryCategory] = []
    var page: DiscoveryPage = .empty
    var isLoading = false
    var failure: String?

    // MARK: Apps

    var appCategoryID: Int?
    var appCategories: [AppDirectoryCategory] = []
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
        ServerRequest(query: query.trimmingCharacters(in: .whitespaces), categoryID: categoryID)
    }

    struct ServerRequest: Hashable, Sendable {
        var query: String
        var categoryID: Int?
        /// Whether this goes to the search route rather than the browse route.
        var isSearch: Bool { !query.isEmpty }
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
    var standing: GuildProfile.Standing?
    var memberCount: Int
    var onlineCount: Int
    /// Whether this server can be looked at before joining. A card that cannot
    /// preview still joins — it simply has no way to be read first.
    var canPreview: Bool
    /// Whether the account is already in it, so the card says "Joined" rather
    /// than offering to join a server the reader is standing in.
    var isJoined: Bool
}
