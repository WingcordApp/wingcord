import SwiftUI
import WingcordCore

// MARK: - The detail pane
//
// The same construction as `SettingsDetailPane`: a scrolling page under the
// window's own toolbar, its name the window's title. Two things differ:
//
//   1. **A save indicator**, because every page here writes to somebody's server
//      and a write that reported nothing would leave the reader guessing. It
//      lives in the toolbar rather than over the content: a banner that covers
//      the field you just edited is a banner that hides its own subject.
//   2. **One pane type, always**, exactly as `WorkspacePane` is — see
//      `INVARIANTS.md` §1. The switch is inside `ServerSettingsPaneContent`,
//      which is internal `_ConditionalContent` under a stable outer type, not a
//      structural swap.

/// What the detail pane shows: a page of the server's settings, or a page of
/// one channel's — Discord's two settings layers, in one window.
enum ServerSettingsPage: Hashable {
    case server(ServerSettingsSection)
    case channel(ChannelID, ChannelSettingsTab)
}

struct ServerSettingsDetailPane: View {
    let store: ServerSettingsStore
    let model: AppModel
    var page: ServerSettingsPage
    /// Under the page's name: the server, or the channel being edited.
    var subtitle: String

    @Environment(\.motion) private var motion

    var body: some View {
        ScrollView(.vertical) {
            ServerSettingsPaneContent(store: store, model: model, page: page)
                .padding(SettingsMetrics.cardInset)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                SaveIndicator(state: store.save)
            }
            // Words about the last write, not a button: no capsule behind them.
            .sharedBackgroundVisibility(.hidden)
        }
        .animation(motion.standard, value: page)
        // The page's own fetch, started when it appears and cancelled with it.
        // Keyed on the page so switching pages starts the next one's.
        .task(id: page) {
            switch page {
            case .server(let section): store.load(section)
            case .channel: store.loadChannelSettings()
            }
        }
    }

    private var title: String {
        switch page {
        case .server(let section): section.title(isCommunity: store.settings.value?.isCommunity ?? false)
        case .channel(_, let tab): tab.title
        }
    }
}

/// What the last write did.
///
/// **In the toolbar, not over the page.** A banner across the content covers the
/// field somebody just edited, which is the one thing they are looking at while
/// waiting to hear whether it took.
///
/// The failure state is the only one that stays: a spinner and a tick are
/// transient by nature, and an error that cleared itself after two seconds is an
/// error nobody read.
private struct SaveIndicator: View {
    var state: ServerSettingsStore.SaveState

    @Environment(\.motion) private var motion

    var body: some View {
        Group {
            switch state {
            case .idle:
                EmptyView()
            case .saving:
                HStack(spacing: Spacing.tight) {
                    ProgressView().controlSize(.small)
                    Text("Saving…")
                        .font(.system(.caption))
                        .foregroundStyle(Ink.secondary)
                }
            case .saved:
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .font(.system(.caption, weight: .medium))
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(.caption, weight: .medium))
                    .foregroundStyle(Palette.destructive)
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // The full text, for a message the toolbar has to truncate.
                    .help(message)
            }
        }
        .animation(motion.fade, value: state)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - The pane

/// One view type for every page. See `INVARIANTS.md` §1 — the switch inside is
/// `_ConditionalContent` under a stable outer type, which is not the structural
/// swap that rule forbids.
private struct ServerSettingsPaneContent: View {
    let store: ServerSettingsStore
    let model: AppModel
    var page: ServerSettingsPage

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch page {
            case .server(let section):
                heading(
                    section.title(isCommunity: store.settings.value?.isCommunity ?? false),
                    detail: section.detail
                )
                serverPage(section)
            case .channel(let channelID, let tab):
                if let channel = model.channelIndex[channelID] {
                    // The Permissions page heads itself, as Discord's does —
                    // "Channel Permissions" or "Category Settings" over its
                    // own line.
                    if tab != .permissions { heading(tab.title, detail: nil) }
                    ChannelSettingsContent(store: store, model: model, channel: channel, tab: tab)
                } else {
                    // Deleted underneath the page — from here or anywhere else.
                    Color.clear
                        .frame(height: 1)
                        .onAppear { store.openChannelID = nil }
                }
            }
        }
    }

    @ViewBuilder
    private func serverPage(_ section: ServerSettingsSection) -> some View {
        switch section {
        case .profile: ServerProfilePane(store: store, model: model)
        case .tag: ServerTagPane(store: store)
        case .serverTheme: ServerThemePane(store: store, model: model)
        case .engagement:
            EngagementPane(
                store: store,
                memberCount: model.guilds[store.guildID]?.memberCount,
                serverHub: model.guilds[store.guildID]?.spaceSettings,
                isServerHubSaving: model.serverHub.settingsInFlight.contains(store.guildID),
                setServerHubEnabled: { [guildID = store.guildID] isOn in
                    model.sessionController.setServerHubEnabled(guildID, isOn: isOn)
                }
            )
        case .boostPerks: BoostPerksPane(store: store, model: model)
        case .emoji: EmojiPane(store: store, model: model)
        case .stickers: StickersPane(store: store, model: model)
        case .soundboard: SoundboardPane(store: store, model: model)
        case .roles: RolesPane(store: store)
        case .invites: InvitesPane(store: store, model: model)
        case .access: AccessPane(store: store, model: model)
        case .integrations: IntegrationsPane(store: store, model: model)
        case .safety: SafetyPane(store: store, model: model)
        case .auditLog: AuditLogPane(store: store)
        case .bans: BansPane(store: store)
        case .community: CommunityPane(store: store)
        case .onboarding: OnboardingPane(store: store)
        case .insights: ServerInsightsPane(guildID: store.guildID)
        case .welcomeScreen: WelcomeScreenPane(store: store, model: model)
        case .template: TemplatePane(store: store)
        // Rows that act rather than open — see `ServerSettingsSection.isAction`.
        case .members, .appDirectory, .deleteServer: EmptyView()
        }
    }

    /// The page's name, and Discord's line under it where it has one.
    ///
    /// Drawn here rather than by each pane, so the panes cannot disagree about
    /// the gap under a title — the same argument `SurfaceHeading` makes for the
    /// reader's server pages.
    private func heading(_ title: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            Text(title)
                .font(.system(.title2, weight: .bold))
                .foregroundStyle(Ink.primary)
            if let detail {
                Text(detail)
                    .font(.system(.subheadline))
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, SettingsMetrics.cardToHeader)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
