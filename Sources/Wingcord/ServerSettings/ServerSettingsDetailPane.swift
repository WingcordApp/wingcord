import SwiftUI
import WingcordCore

// MARK: - The detail pane
//
// The same construction as `SettingsDetailPane`, and the comments there explain
// every number in it — the drawn scroll-edge band, why `safeAreaBar` rather than
// `safeAreaInset`, and why the scrim goes outside the bar. None of that is
// restated here; what follows is only what this pane does *differently*.
//
// Two things do:
//
//   1. **A save banner**, because every page here writes to somebody's server
//      and a write that reported nothing would leave the reader guessing. It
//      lives in the toolbar rather than over the content: a banner that covers
//      the field you just edited is a banner that hides its own subject.
//   2. **One pane type, always**, exactly as `WorkspacePane` is — see
//      `INVARIANTS.md` §1. The switch is inside `ServerSettingsPaneContent`,
//      which is internal `_ConditionalContent` under a stable outer type, not a
//      structural swap.

struct ServerSettingsDetailPane: View {
    let store: ServerSettingsStore
    let model: AppModel
    var section: ServerSettingsSection
    var isSidebarCollapsed: Bool
    var toggleSidebar: () -> Void

    @Environment(\.motion) private var motion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var isScrolled = false

    var body: some View {
        ScrollView(.vertical) {
            ServerSettingsPaneContent(store: store, model: model, section: section)
                .padding(.horizontal, SettingsMetrics.cardInset)
                .padding(.bottom, SettingsMetrics.cardInset)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .floatingTopBar {
            ServerSettingsToolbar(
                title: isScrolled ? section.title : nil,
                save: store.save,
                isSidebarCollapsed: isSidebarCollapsed,
                toggleSidebar: toggleSidebar
            )
        }
        .background(SettingsSurface.pane(reducingTransparency: reduceTransparency))
        .overlay(alignment: .top) { scrollEdgeBand }
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top > 6
        } action: { _, moved in
            isScrolled = moved
        }
        .clipShape(.settingsRect(SettingsMetrics.paneRadius))
        .padding(.vertical, SettingsMetrics.paneInset)
        .padding(.trailing, SettingsMetrics.paneInset)
        .animation(motion.standard, value: section)
        // The page's own fetch, started when it appears and cancelled with it.
        // Keyed on the section so switching pages starts the next one's.
        .task(id: section) { store.load(section) }
    }

    private var scrollEdgeBand: some View {
        LinearGradient(
            stops: [
                .init(color: .black.opacity(SettingsSurface.scrollEdgeTint), location: 0),
                .init(color: .black.opacity(SettingsSurface.scrollEdgeTint), location: 0.36),
                .init(color: .clear, location: 1.0),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: SettingsMetrics.toolbarBandHeight)
        .opacity(isScrolled ? 1 : 0)
        .animation(motion.fade, value: isScrolled)
        .allowsHitTesting(false)
    }
}

// MARK: - The toolbar

private struct ServerSettingsToolbar: View {
    var title: String?
    var save: ServerSettingsStore.SaveState
    var isSidebarCollapsed: Bool
    var toggleSidebar: () -> Void

    @Environment(\.motion) private var motion

    var body: some View {
        HStack(spacing: 12.5) {
            if isSidebarCollapsed {
                Spacer(minLength: 0)
                SettingsSidebarButton(action: toggleSidebar)
            }
            if let title {
                Text(title)
                    .font(SettingsType.sectionHeader)
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
            SaveIndicator(state: save)
        }
        .animation(motion.fade, value: title)
        .padding(.horizontal, 14)
        .frame(height: SettingsMetrics.toolbarItemHeight)
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
    var section: ServerSettingsSection

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading
            switch section {
            case .profile: ServerProfilePane(store: store)
            case .tag: ServerTagPane(store: store)
            case .engagement: EngagementPane(store: store)
            case .events: EventsPane(store: store)
            case .emoji: EmojiPane(store: store, model: model)
            case .stickers: StickersPane(store: store, model: model)
            case .soundboard: SoundboardPane(store: store, model: model)
            case .channels: ChannelsPane(store: store)
            case .members: MembersPane(store: store, model: model)
            case .roles: RolesPane(store: store)
            case .invites: InvitesPane(store: store, model: model)
            case .access: AccessPane(store: store)
            case .integrations: IntegrationsPane(store: store, model: model)
            case .webhooks: WebhooksPane(store: store, model: model)
            case .safety: SafetyPane(store: store)
            case .auditLog: AuditLogPane(store: store)
            case .bans: BansPane(store: store)
            case .community: CommunityPane(store: store)
            case .onboarding: OnboardingPane(store: store)
            case .serverGuide: GuideSettingsPane(store: store)
            case .template: TemplatePane(store: store)
            }
        }
    }

    /// The page's name and what it is for.
    ///
    /// Drawn here rather than by each pane, so eighteen panes cannot disagree
    /// about the gap under a title — the same argument `SurfaceHeading` makes
    /// for the reader's server pages.
    private var heading: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            Text(section.title)
                .font(.system(.title2, weight: .bold))
                .foregroundStyle(Ink.primary)
            Text(section.detail)
                .font(.system(.subheadline))
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, SettingsMetrics.cardToHeader)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
