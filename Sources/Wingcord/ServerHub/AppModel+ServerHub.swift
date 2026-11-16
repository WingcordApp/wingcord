import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WingcordCore

// MARK: - Server Hub: who sees it, and what editing does
//
// docs/BETA2.md, phase 9 and decisions 13–14. The page itself is
// `ServerHubPage`; the routes are `SessionController+ServerHub`.

extension AppModel {

    /// Discord's whiteboard app, which the hub's whiteboard widget runs.
    static let whiteboardApplicationID = ApplicationID(rawValue: 1_070_087_967_294_631_976)

    /// The server experiment Discord rolls the hub out with (`256497`).
    static let serverHubExperiment = "2026-09-guild-spaces"

    /// The largest banner or picture Discord's own editor accepts (`0xa00000`).
    static let serverHubImageLimit = 10 * 1024 * 1024

    /// Whether the reader may edit a server's hub — Manage Server, Discord's
    /// `mN`.
    func canEditServerHub(_ guildID: GuildID) -> Bool {
        // `--demo`'s account is a member of The Iris Project, not its admin —
        // the server's other fixtures depend on that — so the demo's hub is
        // editable on its own say-so, to show the editor at all.
        if LaunchOptions.current.usesDemoFixtures, guildID == DemoFixtures.serverHubGuild { return true }
        return permissionGate.permissions(inGuild: guildID).contains(.manageGuild)
    }

    /// Whether a server's channel list offers its Server Hub.
    ///
    /// **Only where Discord has given the server one** (D14): its settings on
    /// the guild, the hub's own channel, or (for the people who can make one)
    /// Discord's own experiment saying the server has the feature. Wingcord
    /// never turns it on for a server; it only shows what Discord already
    /// decided. Within that, Discord's own rule (`GuildSpaceSettings.isVisible`):
    /// editors see a draft, everyone sees a published hub, nobody sees one
    /// switched off. And the Settings › Experiments switch is the reader's:
    /// off, nothing here.
    func offersServerHub(_ guildID: GuildID) -> Bool {
        guard AppSettings.shared.showsServerHub, let guild = guilds[guildID] else { return false }
        let isEditor = canEditServerHub(guildID)
        if let settings = guild.spaceSettings {
            guard settings.isVisible(toEditor: isEditor) else { return false }
            // Discord answered that there's none yet: the page is for making one.
            return !serverHub.missing.contains(guildID) || isEditor
        }
        // No hub yet, in a server Discord has put in the experiment: Discord's
        // channel list offers its editors the row, to make one (`313627`'s
        // `c` with no settings at all).
        if isEditor, isInServerHubExperiment(guild) == true { return true }
        guard hasServerHubChannel(guildID) else { return false }
        return serverHub.spaces[guildID]?.widgets.isEmpty == false
    }

    /// Whether Discord might have a hub for this server — worth asking about.
    func mayHaveServerHub(_ guildID: GuildID) -> Bool {
        guard AppSettings.shared.showsServerHub, let guild = guilds[guildID] else { return false }
        return guild.spaceSettings != nil || hasServerHubChannel(guildID)
            || (canEditServerHub(guildID) && isInServerHubExperiment(guild) == true)
    }

    /// Whether Discord has given this server the Server Hub: its
    /// `2026-09-guild-spaces` assignment, evaluated as Discord's client does
    /// (`Experiments.guildVariant`), variant 1 being "on". Nil where READY
    /// said nothing either way (no assignments for the reader, or none on the
    /// server's object), so the answer is unknown rather than no.
    ///
    /// **Used only to offer more, never to hide.** The hub's settings already
    /// say where Discord shows one, and a misread experiment must not take a
    /// published hub away.
    func isInServerHubExperiment(_ guild: Guild) -> Bool? {
        guard let assignments = guild.apexAssignments, !experiments.apexReader.isEmpty else { return nil }
        return Experiments.guildVariant(
            Self.serverHubExperiment, reader: experiments.apexReader, guild: assignments
        ) == 1
    }

    func hasServerHubChannel(_ guildID: GuildID) -> Bool {
        channelIndex.channelIDs(inGuild: guildID).contains { channelIndex[$0]?.kind == .guildSpace }
    }

    // MARK: Opening

    /// What the page asks for as it appears: the hub, its widgets' data, and
    /// the server's profile for the online count under its name.
    func prepareServerHub(_ guildID: GuildID) {
        sessionController.loadServerHub(guildID)
        sessionController.hydrateServerHub(guildID)
        if guildProfiles[guildID] == nil { loadGuildProfile(guildID) }
    }

    /// The reader turned Settings › Experiments › Server Hub on or off: the
    /// channel list gains or loses its row, and the open server is asked about.
    func serverHubSwitchChanged() {
        if AppSettings.shared.showsServerHub {
            if let guildID = selectedGuildID, mayHaveServerHub(guildID) {
                sessionController.loadServerHub(guildID)
            }
        } else {
            serverHub.draft = nil
            serverHub.sheet = nil
            if openGuildSurface == .serverHub { openGuildSurface = nil }
        }
        sidebarRevision &+= 1
    }

    func retryServerHub(_ guildID: GuildID) {
        serverHub.failed.remove(guildID)
        sessionController.loadServerHub(guildID, force: true)
    }

    func openServerHub(in guildID: GuildID? = nil) {
        openSurface(.serverHub, inGuild: guildID ?? selectedGuildID)
    }

    /// Server Settings › Engagement, where the hub is switched on or off and
    /// its system messages are.
    func openServerHubSettings() {
        guard let guildID = selectedGuildID else { return }
        ServerSettingsWindow.open(guildID, section: .engagement)
    }

    // MARK: Editing

    var isEditingServerHub: Bool {
        serverHub.draft != nil && serverHub.draft?.guildID == selectedGuildID
    }

    /// Starts an edit of the server on screen — Discord's `Wd`. A server with
    /// no hub starts from Discord's own first layout.
    func beginServerHubEdit() {
        guard let guildID = selectedGuildID, canEditServerHub(guildID), serverHub.draft?.guildID != guildID else { return }
        let space = serverHub.spaces[guildID]
        let widgets = space?.widgets ?? starterServerHubWidgets(guildID)
        serverHub.draft = ServerHubDraft(guildID: guildID, widgets: widgets, isNewHub: space == nil)
        sessionController.loadServerHubCatalog(guildID)
    }

    /// Puts everything back by keeping nothing.
    func cancelServerHubEdit() {
        serverHub.draft = nil
        serverHub.sheet = nil
    }

    func saveServerHubEdit() {
        sessionController.saveServerHub()
    }

    /// Discord's starting layout (`GuildSpaceLayout.starterKinds`), named from
    /// the catalog where it has answered.
    private func starterServerHubWidgets(_ guildID: GuildID) -> [GuildSpaceWidget] {
        let catalog = serverHub.catalogs[guildID]
        return GuildSpaceLayout.starterKinds.enumerated().flatMap { column, kinds in
            kinds.compactMap { kind -> GuildSpaceWidget? in
                let entry = catalog?.first { $0.kind == kind }
                if catalog != nil, entry == nil { return nil }
                return GuildSpaceWidget(
                    id: ServerHubDraft.draftID(),
                    kind: kind,
                    position: .init(column: column, order: 0),
                    defaultTitle: entry?.name ?? ServerHubWidgetNames.defaultTitle(kind),
                    isLocked: entry?.isLocked ?? false
                )
            }
        }
    }

    /// Every change to the edit comes through here, so a failed save's message
    /// goes the moment the reader does something about it.
    private func editServerHubDraft(_ change: (inout ServerHubDraft) -> Void) {
        guard var draft = serverHub.draft else { return }
        change(&draft)
        if case .failed = draft.saveState { draft.saveState = .idle }
        serverHub.draft = draft
    }

    func addServerHubWidget(_ entry: GuildSpaceCatalogEntry, column: Int, index: Int) {
        guard serverHub.draft != nil else { return }
        let widget = GuildSpaceWidget(
            id: ServerHubDraft.draftID(),
            kind: entry.kind,
            position: .init(column: column, order: index),
            defaultTitle: entry.name,
            isLocked: entry.isLocked
        )
        editServerHubDraft { $0.widgets = GuildSpaceLayout.inserting(widget, into: $0.widgets, column: column, index: index) }
        // An empty Image + Text is no use to anyone: it opens on its words.
        serverHub.sheet = entry.kind == .imageText ? .imageText(widgetID: widget.id) : nil
    }

    func removeServerHubWidget(_ id: String) {
        editServerHubDraft { $0.widgets = GuildSpaceLayout.removing(id, from: $0.widgets) }
    }

    func moveServerHubWidget(_ id: String, toColumn column: Int, index: Int) {
        guard let draft = serverHub.draft,
              let moved = GuildSpaceLayout.moving(id, in: draft.widgets, toColumn: column, index: index)
        else { return }
        editServerHubDraft { $0.widgets = moved }
    }

    /// A drop from the grid's reorder container: where the dragged card goes,
    /// as the column it landed in and the card it landed before.
    func applyServerHubReorder(_ difference: ReorderDifference<String, Int>) {
        guard let moved = difference.sources.first else { return }
        let following: String? = switch difference.destination.position {
        case .before(let id): id
        case .end: nil
        }
        dropServerHubWidget(moved, inColumn: difference.destination.collectionID, before: following)
    }

    /// A card dropped into a column, before another card or at its end.
    /// (`ReorderDifference` has no public initialiser; this is the half a test
    /// can reach.)
    func dropServerHubWidget(_ id: String, inColumn column: Int, before following: String?) {
        guard let draft = serverHub.draft else { return }
        let target = GuildSpaceLayout.columns(draft.widgets.filter { $0.id != id })[column == GuildSpaceLayout.sideColumn ? 1 : 0]
        let index = following.flatMap { next in target.firstIndex { $0.id == next } } ?? target.count
        moveServerHubWidget(id, toColumn: column, index: index)
    }

    func updateServerHubWidget(_ id: String, config: GuildSpaceWidgetConfig) {
        guard let index = serverHub.draft?.widgets.firstIndex(where: { $0.id == id }) else { return }
        editServerHubDraft { $0.widgets[index].config = config }
    }

    /// A banner picked from disk: checked against Discord's 10 MB, kept as the
    /// data URL a save sends.
    func setServerHubBanner(from url: URL) {
        guard serverHub.draft != nil else { return }
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        guard let picture = Self.serverHubImage(at: url) else {
            reportActionFailure("Pick a picture up to 10 MB.")
            return
        }
        editServerHubDraft { $0.banner = .replaced(dataURL: picture.dataURL, preview: picture.data) }
    }

    func removeServerHubBanner() {
        editServerHubDraft { $0.banner = .removed }
    }

    /// A picture file as a data URL, or nil when it isn't one or is too big.
    static func serverHubImage(at url: URL) -> (data: Data, dataURL: String)? {
        guard let data = try? Data(contentsOf: url), data.count <= serverHubImageLimit,
              NSImage(data: data) != nil
        else { return nil }
        let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "image/png"
        return (data, "data:\(type);base64,\(data.base64EncodedString())")
    }

    // MARK: Publishing and the whiteboard

    func publishServerHub() {
        guard let guildID = selectedGuildID else { return }
        sessionController.publishServerHub(guildID)
    }

    func launchWhiteboard() {
        guard let guildID = selectedGuildID else { return }
        Task { await sessionController.launchWhiteboard(in: guildID) }
    }

    /// Leaving the page takes the whiteboard with it, as Discord's does: it is
    /// drawn only here, and an activity nobody can see is still a session.
    func leaveServerHub(_ guildID: GuildID) {
        guard let channelID = serverHub.spaces[guildID]?.channelID,
              runningActivity?.instance.location.channelID == channelID
        else { return }
        Task { await sessionController.leaveActivity() }
    }

    /// Who may draw: the roles allowed Use Activities in the hub's channel, or
    /// nobody singled out when everyone may (Discord's whiteboard settings).
    func whiteboardRoleIDs(_ guildID: GuildID) -> Set<RoleID> {
        guard let channelID = serverHub.spaces[guildID]?.channelID,
              let channel = channelIndex[channelID]
        else { return [] }
        let everyone = channel.overwrites.first { $0.subject == .role && $0.id == guildID.rawValue }
        guard everyone?.deny.contains(.useEmbeddedActivities) == true else { return [] }
        return Set(channel.overwrites.compactMap { overwrite in
            overwrite.subject == .role && overwrite.allow.contains(.useEmbeddedActivities)
                ? RoleID(rawValue: overwrite.id) : nil
        })
    }

    func setWhiteboardRoles(_ roleIDs: Set<RoleID>) {
        guard let guildID = selectedGuildID else { return }
        sessionController.setWhiteboardRoles(roleIDs, in: guildID)
    }
}
