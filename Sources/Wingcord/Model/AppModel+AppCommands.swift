import Foundation
import WingcordCore
import WingcordNet

// MARK: - "Use this app"
//
// An application's own page, as a list of the commands it registers. The same
// index the `/` list is built from — `GET /applications/{id}/application-command-index`,
// 7,700 bytes for OwO and 33 KB for Dank Memer — narrowed to one application and
// grouped the way its page groups it.
//
// Captured in `OwO app commands full.har` and `dank memer.har` (2026-09-03).

/// One command on an application's page.
///
/// **The trailing control is decided by whether the leaf takes anything.** Both
/// captures agree on every row: `gen emergency`, `dig`, `hunt` and `work list`
/// have no options and draw **Send**; `gen eject`, `gen headpat emoji`,
/// `gen headpat user` and `work apply` each take one and draw a **chevron** into
/// the composer instead. Nothing else separates them — not the type, not the
/// depth, not the popularity.
struct AppCommandRow: Hashable, Sendable, Identifiable {
    var id: String
    var command: SlashCommand
    /// Whether pressing it runs the command outright. False when it has options
    /// to fill, which sends the reader to the composer with the command already
    /// in the bar.
    var sendsImmediately: Bool
}

/// A titled group on an application's page.
struct AppCommandSection: Hashable, Sendable, Identifiable {
    var id: String
    var title: String
    var rows: [AppCommandRow]
}

extension AppModel {

    /// What an application's page draws under its description.
    ///
    /// Memoized on the same revision the `/` list uses: the index landing is the
    /// only thing that can change it, and the page is re-evaluated on every
    /// scroll of the flyout.
    func appCommandSections(for id: ApplicationID) -> [AppCommandSection] {
        let key = AppCommandMemoKey(revision: commandRevision, applicationID: id)
        // Every observable input is read before the early return: a memo that
        // answers from its cache without touching them registers no dependency
        // and is never invalidated again. `INVARIANTS.md` §2.
        let indexes = commandIndexes
        let frecency = commandFrecency
        let uses = commandUses

        if let appCommandSectionsCache, appCommandSectionsCache.key == key {
            return appCommandSectionsCache.value
        }
        let sections = Self.buildAppCommandSections(
            id: id,
            indexes: indexes,
            frecency: frecency,
            uses: uses
        )
        appCommandSectionsCache = (key, sections)
        return sections
    }

    /// The entry point this application launches from, if its own index carries
    /// one.
    ///
    /// **Nil is not "cannot launch".** Wordle's `play` lives in the account
    /// index and not in the app-scoped one, so an app can be perfectly
    /// launchable with nothing here — which is why this decides the button's
    /// *words* and never whether it is drawn. `ActivityApp.isLaunchable` is what
    /// decides that.
    func appEntryPoint(for id: ApplicationID) -> ActivityEntryPoint? {
        commandIndexes[.application(id)]?.entryPoint
            ?? commandIndexes[.account]?.entryPoint(for: id)
    }

    /// Whether this application says it has a storefront.
    ///
    /// **Discord's own answer, on the application object** — `storefront_available`
    /// from `GET /applications/{id}/public`, fetched with the page. An app that
    /// says it has none never shows a row that opens onto nothing, and one that
    /// has not answered yet shows none either: absent is "not asked", and a
    /// menu that grows a row a beat after opening is worse than one that does
    /// not.
    func applicationHasStorefront(_ id: ApplicationID) -> Bool {
        let _ = storeRevision
        return applicationStorefronts[id] == true
    }

    private static func buildAppCommandSections(
        id: ApplicationID,
        indexes: [DiscordREST.CommandScope: CommandIndex],
        frecency: [String],
        uses: [String: Date]
    ) -> [AppCommandSection] {
        guard let index = indexes[.application(id)] else { return [] }
        let leaves = index.slashCommands
        guard !leaves.isEmpty else { return [] }

        func row(_ leaf: SlashCommand, in section: String) -> AppCommandRow {
            AppCommandRow(
                id: section + "/" + leaf.id,
                command: leaf,
                // A command whose only options this client cannot fill — an
                // attachment, say — still sends outright, because there is
                // nothing for the composer to ask for.
                sendsImmediately: leaf.offeredParameters.isEmpty
            )
        }

        var sections: [AppCommandSection] = []

        // **Recents, from the account's own command frecency**, narrowed to this
        // application. The same table the `/` list's Frequently Used is drawn
        // from — field 7 of the second settings protobuf — which is why an app's
        // page can show one without a route of its own. OwO's page draws
        // `gen eject` here, and that is the command the account had just run.
        let byID = Dictionary(leaves.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        let recent = (uses.sorted { $0.value > $1.value }.map(\.key) + frecency)
            .filter { seen.insert($0).inserted }
            .compactMap { byID[$0] }
            .prefix(recentAppCommandsShown)
        if !recent.isEmpty {
            sections.append(AppCommandSection(
                id: "recents",
                title: "Recents",
                rows: recent.map { row($0, in: "recents") }
            ))
        }

        // Then everything, in Discord's own popularity order. Its page offers a
        // sort control; this does not, and the reason is that the alternative
        // ordering — alphabetical — is what the list already looks like for an
        // app whose commands are unranked, and a control that reorders four rows
        // is a control nobody reaches for.
        sections.append(AppCommandSection(
            id: "all",
            title: "Use this app",
            rows: leaves
                .sorted {
                    let left = $0.popularityRank ?? .max
                    let right = $1.popularityRank ?? .max
                    if left != right { return left < right }
                    return $0.name < $1.name
                }
                .map { row($0, in: "all") }
        ))
        return sections
    }

    /// How many rows Recents offers. Past a couple it stops being a shortcut and
    /// becomes a second copy of the list under it.
    private static let recentAppCommandsShown = 3
}

/// What an application's command list is memoized on.
struct AppCommandMemoKey: Hashable, Sendable {
    var revision: UInt64
    var applicationID: ApplicationID
}
