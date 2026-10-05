import SwiftUI
import WingcordCore

/// A server's events — Discord's events list (`318104`) and an event's own
/// page (`640132`) — as one layer over the window.
///
/// **A layer, not a `.sheet`**, for the reactors list's reason: a profile
/// opened from somebody interested, or the person menu a right-click raises,
/// must come up above it in the same window, and Escape closes whichever is
/// on top (`EscapeLayer`). One layer for both pages, because Discord's list
/// opens the details over itself and closing the details returns to the list —
/// here the details replace the list and Back returns to it.
///
/// Clear glass over `Palette.modalScrim` — the quick switcher's recipe, for its
/// reason: cards of text over a transcript are unreadable through clear glass
/// alone, and frosting it is the slab §4 exists to avoid.
struct EventsLayer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion

    /// Discord's list is a medium modal and its details a large one; one size
    /// serves both here, so turning the page does not move the panel's edges.
    private static let width: CGFloat = 560
    private static let height: CGFloat = 680
    private static let inset: CGFloat = 32

    var body: some View {
        let request = model.eventsPanel
        ZStack {
            if let request {
                Button { model.eventsPanel = nil } label: {
                    Palette.modalScrim.contentShape(.rect)
                }
                .buttonStyle(.plain)
                .cancelAction(unless: model.isCovered(.events))
                .accessibilityLabel(Text("Close events"))
                .ignoresSafeArea()
                .transition(.opacity)

                EventsPanel(request: request)
                    .id(request.guildID)
                    .frame(maxWidth: Self.width, maxHeight: Self.height)
                    .padding(Self.inset)
                    .transition(.materialize)
            }
        }
        .animation(motion.panel, value: request?.guildID)
    }
}

/// The panel: a header, and the list or one event under it.
private struct EventsPanel: View {
    var request: EventsPanelRequest

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        Group {
            switch request.page {
            case .list:
                EventsListPage(guildID: request.guildID, newSince: request.newSince)
                    .transition(.opacity)
            case .event(let eventID, let occurrence):
                if let event = model.scheduledEvents[request.guildID]?.first(where: { $0.id == eventID }) {
                    EventDetailPage(event: event, requested: occurrence)
                        .id(eventID)
                        .transition(.opacity)
                } else {
                    // Gone while it was open — deleted, or ended and dropped.
                    // Discord's details close themselves; the list is what is
                    // left to show here.
                    Color.clear.onAppear { model.showEventsList() }
                }
            }
        }
        .animation(motion.fadeQuick, value: request.page)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .glassEffect(.clear.tint(Palette.flyoutTint), in: shape)
        .specularEdge(in: shape)
    }
}

/// The header both pages share: a title, what leads it, and Close.
struct EventsPanelHeader<Leading: View, Trailing: View>: View {
    var title: String
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Spacing.base) {
            leading
            Text(title)
                .font(.system(.headline))
                .foregroundStyle(InkColor.primary)
                .lineLimit(1)
            trailing
            Spacer(minLength: 0)
            Button { model.eventsPanel = nil } label: {
                Image(systemName: "xmark")
                    .font(.system(.body, weight: .semibold))
                    .foregroundStyle(InkColor.solid)
                    .frame(width: Metrics.control, height: Metrics.control)
                    // A region inside the panel's material, not a body of its
                    // own — glass on glass is §4's first rule.
                    .background(Circle().fill(Palette.hoverFill))
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .help("Close")
            .accessibilityLabel(Text("Close events"))
        }
        .padding(Spacing.margin)
    }
}

// MARK: - The list

/// Every event on or still to come, as Discord's modal lists them: a card
/// each, newest-to-the-reader marked NEW.
private struct EventsListPage: View {
    var guildID: GuildID
    var newSince: UInt64?

    @Environment(AppModel.self) private var model

    var body: some View {
        let events = model.upcomingEvents(inGuild: guildID)
        let canCreate = model.canManageEvents(inGuild: guildID)
        VStack(spacing: 0) {
            EventsPanelHeader(title: events.isEmpty ? "Events" : "\(events.count) \(events.count == 1 ? "Event" : "Events")") {
                Image(systemName: "calendar")
                    .font(.system(.body, weight: .semibold))
                    .foregroundStyle(InkColor.secondary)
                    .accessibilityHidden(true)
            } trailing: {
                if canCreate {
                    Button("Create Event") {
                        model.openEventEditor(inGuild: guildID)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(.leading, Spacing.tight)
                }
            }
            Rectangle().fill(Palette.selectionFill).frame(height: 1)
            if events.isEmpty {
                EventsEmptyState(guildID: guildID)
            } else {
                ScrollView {
                    LazyVStack(spacing: Spacing.snug) {
                        ForEach(events) { event in
                            EventCard(event: event, isNew: model.isNew(event, since: newSince))
                        }
                    }
                    .padding(Spacing.margin)
                }
                .scrollIndicators(.automatic)
                .softScrollEdgesVertical()
            }
        }
    }
}

/// Nothing coming — Discord's own words, and for somebody who hands out roles,
/// where the permission to make events is given.
private struct EventsEmptyState: View {
    var guildID: GuildID

    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: Spacing.snug) {
            Image(systemName: "calendar")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(InkColor.tertiary)
                .accessibilityHidden(true)
            Text("There are no upcoming events.")
                .font(.system(.title3, weight: .semibold))
                .foregroundStyle(InkColor.primary)
            Text("Schedule an event for any planned activity in your server.")
                .font(.system(.subheadline))
                .foregroundStyle(InkColor.secondary)
            if model.permissionGate.permissions(inGuild: guildID).contains(.manageRoles) {
                Button {
                    model.eventsPanel = nil
                    ServerSettingsWindow.open(guildID, section: .roles)
                } label: {
                    let link = Text("Server Settings > Roles").bold().foregroundStyle(Palette.accent)
                    Text("You can give other people permission to create events in \(link).")
                        .foregroundStyle(InkColor.secondary)
                }
                .buttonStyle(.plain)
                .font(.system(.subheadline))
            }
        }
        .multilineTextAlignment(.center)
        .padding(Spacing.section)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
