import Foundation
import Observation
import WingcordCore

/// One Mod View: a moderator's look at one person in one server.
///
/// **Three answers, fetched together and refreshed together** — Discord's own
/// Mod View (`94c16fc4`) asks for the same three on open and on Refresh: the
/// counts behind Server Activity (`messages/search/tabs`), what was done to
/// them (`audit-logs?target_id=`), and how they got in
/// (`members/supplemental`). The member and their profile are asked of the
/// gateway and the profile route beside them, so the roles and dates are
/// current too.
@MainActor
@Observable
final class ModViewStore {
    /// Mod View's panels (`486974`). Message History is the app's search
    /// panel, pointed at them — see `ModViewPane`.
    enum Panel: Hashable {
        case info
        case permissions
        case auditLog
    }

    struct Loaders {
        var counts: @MainActor (GuildID, UserID) async throws -> MemberActivityCounts
        var auditLog: @MainActor (GuildID, UserID) async throws -> AuditLogPage
        var joinSource: @MainActor (GuildID, UserID) async throws -> GuildMemberRow.JoinSource?
        /// The member and their profile, asked again.
        var refreshMember: @MainActor (GuildID, UserID) -> Void
    }

    let guildID: GuildID
    let userID: UserID
    var panel = Panel.info
    /// Nil while Discord is counting; zeroes where it would not say, as
    /// Discord's own panel shows them.
    private(set) var counts: MemberActivityCounts?
    /// The audit log for them, merged the way Discord merges it. Nil while
    /// loading.
    private(set) var auditGroups: [AuditLogMerge.Group]?
    private(set) var auditPage: AuditLogPage?
    private(set) var auditFailed = false
    /// How they got in. Nil until the supplemental route answers.
    private(set) var joinSource: GuildMemberRow.JoinSource?
    private(set) var isRefreshing = false

    @ObservationIgnored private let loaders: Loaders
    /// Bumped per load, so an answer to an older one is dropped.
    @ObservationIgnored private var generation = 0

    init(guildID: GuildID, userID: UserID, loaders: Loaders) {
        self.guildID = guildID
        self.userID = userID
        self.loaders = loaders
    }

    func load() {
        generation &+= 1
        let ticket = generation
        counts = nil
        auditGroups = nil
        auditFailed = false
        Task { [weak self] in
            guard let self else { return }
            let answer = try? await loaders.counts(guildID, userID)
            guard ticket == generation else { return }
            counts = answer ?? MemberActivityCounts(messages: 0, links: 0, media: 0)
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await loaders.auditLog(guildID, userID)
                guard ticket == generation else { return }
                auditPage = page
                auditGroups = AuditLogMerge.groups(page.entries)
            } catch {
                guard ticket == generation else { return }
                auditFailed = true
                auditGroups = []
            }
        }
        Task { [weak self] in
            guard let self else { return }
            let source = try? await loaders.joinSource(guildID, userID)
            guard ticket == generation, let source else { return }
            joinSource = source
        }
    }

    /// Mod View's Refresh: everything again, with the spinner held for at
    /// least a second, as Discord holds it, so a quick answer still reads as
    /// having been asked.
    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        loaders.refreshMember(guildID, userID)
        load()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.isRefreshing = false
        }
    }
}
