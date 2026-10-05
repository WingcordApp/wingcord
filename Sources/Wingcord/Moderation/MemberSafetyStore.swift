import Foundation
import Observation
import WingcordCore

/// The Members page: Discord's member-safety search for one server, paged the
/// way its table pages it.
///
/// **Fetched in chunks, paged on the client** — Discord's own store (`151781`)
/// works the same way. The route answers up to 250 rows with a cursor; the
/// table shows 12, 25, 50 or 100 of them per page; a page past what is loaded
/// asks for the next chunk.
///
/// **A moderation act lands here too.** A kick or a ban takes the row out and
/// a member write updates it in place, through `remove` and `update` — so the
/// table never shows somebody who was just removed, and nothing refetches.
@MainActor
@Observable
final class MemberSafetyStore {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        /// A 202, twice: the server is still being indexed.
        case indexing
        case failed(String)
    }

    typealias Search = @MainActor (GuildID, MemberSearchQuery, MemberSearchCursor?) async throws
        -> MemberSearchPage?

    /// The member applications behind the page's other three tabs.
    struct Applications {
        var list: @MainActor (GuildID, GuildJoinRequest.Status) async throws -> [GuildJoinRequest]
        /// Approve, or reject with Discord's optional denial reason.
        var resolve: @MainActor (GuildID, UInt64, Bool, String?) async throws -> Void
        /// Discord's Interview: opens — or enters — the conversation with the
        /// applicant, and goes there.
        var interview: @MainActor (GuildJoinRequest) async throws -> Void
    }

    /// Discord's tabs (`e4`): All Members, then the applications by status —
    /// shown only where the server reviews applications.
    enum Tab: Hashable {
        case members
        case applications(GuildJoinRequest.Status)
    }

    let guildID: GuildID
    private(set) var query = MemberSearchQuery()
    private(set) var rows: [GuildMemberRow] = []
    /// How many match in all — the route's own count, not the rows loaded.
    private(set) var total = 0
    private(set) var phase: Phase = .idle
    private(set) var isLoadingMore = false
    private(set) var pageSize = MemberSafetyStore.pageSizes[0]
    private(set) var page = 1
    /// The rows ticked for a bulk ban.
    var selection: Set<UserID> = []
    private(set) var tab = Tab.members
    /// Each status's applications, once asked for. Absent is "not asked".
    private(set) var applications: [GuildJoinRequest.Status: [GuildJoinRequest]] = [:]
    private(set) var applicationFailure: String?
    /// Applications being approved, rejected or interviewed.
    private(set) var resolving: Set<UInt64> = []

    @ObservationIgnored private var cursor: MemberSearchCursor?
    @ObservationIgnored private var hasMore = false
    /// Bumped by every new search, so an answer to an older one is dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let search: Search
    @ObservationIgnored private let applicationLoaders: Applications?

    /// Discord's page sizes (`233693`), the first being its default.
    static let pageSizes = [12, 25, 50, 100]
    /// Discord's page buttons: seven at most.
    static let maximumVisiblePages = 7
    /// How long a 202 is waited out before asking once more.
    static let indexRetry = Duration.seconds(3)

    init(guildID: GuildID, applications: Applications? = nil, search: @escaping Search) {
        self.guildID = guildID
        self.applicationLoaders = applications
        self.search = search
    }

    // MARK: Reading

    /// The rows on the current page.
    var pageRows: ArraySlice<GuildMemberRow> {
        let start = (page - 1) * pageSize
        guard start < rows.count else { return [] }
        return rows[start..<min(rows.count, start + pageSize)]
    }

    var pageCount: Int { max(1, Int((Double(total) / Double(pageSize)).rounded(.up))) }

    /// "Recent Members" for the default query, "Search Results" otherwise.
    var title: String { query.isDefault ? "Recent Members" : "Search Results" }

    // MARK: Searching

    /// The first search, once.
    func start() {
        guard phase == .idle else { return }
        run(query)
    }

    /// A new query from the page's search box, filters or sort.
    func apply(_ next: MemberSearchQuery) {
        guard next != query else { return }
        run(next)
    }

    /// The same query again — after a prune, or from the refresh control.
    func refresh() {
        run(query)
    }

    func setPageSize(_ size: Int) {
        guard Self.pageSizes.contains(size), size != pageSize else { return }
        pageSize = size
        page = 1
        fillPage()
    }

    func show(page next: Int) {
        let clamped = min(max(1, next), pageCount)
        guard clamped != page else { return }
        page = clamped
        fillPage()
    }

    private func run(_ next: MemberSearchQuery) {
        generation &+= 1
        let ticket = generation
        query = next
        page = 1
        cursor = nil
        hasMore = false
        isLoadingMore = false
        selection = []
        phase = .loading
        Task { [weak self] in
            guard let self else { return }
            do {
                var answer = try await search(guildID, next, nil)
                if answer == nil {
                    try await Task.sleep(for: Self.indexRetry)
                    guard ticket == generation else { return }
                    answer = try await search(guildID, next, nil)
                }
                guard ticket == generation else { return }
                guard let answer else {
                    phase = .indexing
                    return
                }
                rows = answer.rows
                total = answer.total
                cursor = answer.nextCursor
                hasMore = rows.count < total && cursor != nil
                phase = .loaded
                fillPage()
            } catch {
                guard ticket == generation else { return }
                phase = .failed(SessionController.describe(error))
            }
        }
    }

    /// Fetches the next chunk while the current page reaches past the rows
    /// loaded.
    private func fillPage() {
        guard phase == .loaded, hasMore, !isLoadingMore, page * pageSize > rows.count,
              let cursor
        else { return }
        let ticket = generation
        isLoadingMore = true
        Task { [weak self] in
            guard let self else { return }
            let answer = try? await search(guildID, query, cursor)
            guard ticket == generation else { return }
            isLoadingMore = false
            guard let answer else { return }
            let known = Set(rows.map(\.id))
            rows += answer.rows.filter { !known.contains($0.id) }
            self.cursor = answer.nextCursor
            hasMore = !answer.rows.isEmpty && rows.count < total && answer.nextCursor != nil
            fillPage()
        }
    }

    // MARK: Applications

    func show(_ next: Tab) {
        tab = next
        if case .applications(let status) = next { prefetch(status) }
    }

    /// Somebody's application changed — a moderator hears every one
    /// (`GUILD_JOIN_REQUEST_*`), and Discord's list moves with them.
    ///
    /// **The tab on screen is asked again and keeps its rows until the answer
    /// lands**; the other two are forgotten, so they ask when next opened. A
    /// list emptied first would flash its spinner on every application that
    /// arrives.
    func applicationsDidChange(in guildID: GuildID) {
        guard guildID == self.guildID, applicationLoaders != nil else { return }
        guard case .applications(let current) = tab else {
            applications = [:]
            return
        }
        applications = applications.filter { $0.key == current }
        loadApplications(current)
    }

    /// One status's applications, if they have not been asked for.
    func prefetch(_ status: GuildJoinRequest.Status) {
        guard applications[status] == nil else { return }
        loadApplications(status)
    }

    private func loadApplications(_ status: GuildJoinRequest.Status) {
        guard let applicationLoaders else { return }
        applicationFailure = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                applications[status] = try await applicationLoaders.list(guildID, status)
            } catch {
                applicationFailure = SessionController.describe(error)
            }
        }
    }

    /// Approves or rejects one. The application leaves Pending at once; the
    /// tab it lands on is asked again the next time it is opened, and an
    /// approval is a new member, so the table searches again.
    ///
    /// - Parameter reason: Discord's "Provide a denial reason to the user"
    ///   — optional, and only ever sent with a rejection.
    func resolve(_ request: GuildJoinRequest, approve: Bool, reason: String? = nil) {
        guard let applicationLoaders, resolving.insert(request.id).inserted else { return }
        Task { [weak self] in
            guard let self else { return }
            defer { resolving.remove(request.id) }
            do {
                try await applicationLoaders.resolve(guildID, request.id, approve, approve ? nil : reason)
                applications[.submitted]?.removeAll { $0.id == request.id }
                applications[approve ? .approved : .rejected] = nil
                if approve { refresh() }
            } catch {
                applicationFailure = SessionController.describe(error)
            }
        }
    }

    /// Discord's Interview, Open Interview and Join Interview — one act: the
    /// conversation with the applicant, made if it is not there yet.
    func interview(_ request: GuildJoinRequest) {
        guard let applicationLoaders, resolving.insert(request.id).inserted else { return }
        Task { [weak self] in
            guard let self else { return }
            defer { resolving.remove(request.id) }
            do {
                try await applicationLoaders.interview(request)
            } catch {
                // Discord's own words for the failure (`123393`'s toast).
                applicationFailure = "Oops, something went wrong..."
            }
        }
    }

    // MARK: Moderation, landing

    func remove(_ userID: UserID, from guildID: GuildID) {
        guard guildID == self.guildID, let index = rows.firstIndex(where: { $0.id == userID }) else {
            return
        }
        rows.remove(at: index)
        total = max(0, total - 1)
        selection.remove(userID)
        page = min(page, pageCount)
    }

    func update(_ member: Member, in guildID: GuildID) {
        guard guildID == self.guildID,
              let index = rows.firstIndex(where: { $0.id == member.userID })
        else { return }
        rows[index].nickname = member.nickname
        rows[index].roleIDs = member.roleIDs
        rows[index].timedOutUntil = member.communicationDisabledUntil
        rows[index].flags = member.flags
        rows[index].isPending = member.isPending
    }

    func clearSelection(in guildID: GuildID) {
        guard guildID == self.guildID else { return }
        selection = []
    }
}
