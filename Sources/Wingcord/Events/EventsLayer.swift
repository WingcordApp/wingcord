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
/// A solid panel over `Palette.modalScrim` — `ModalPanelBackground`. It was
/// clear glass, and cards of text over a transcript read through it.
struct EventsLayer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion

    /// Discord's list is a medium modal and its details a large one; one size
    /// serves both here, so turning the page does not move the panel's edges.
    /// **Smaller since 2026-11-18** (Alex: "making it smaller"): at 560 by
    /// 680 an event's details filled half of it and left the rest empty.
    private static let width: CGFloat = 520
    private static let height: CGFloat = 560
    private static let inset: CGFloat = 32

    var body: some View {
        let request = model.eventsPanel
        ZStack {
            if let request {
                Button { model.eventsPanel = nil } label: {
                    // The cards' dimming: the panel is solid now, so the
                    // window only has to step back, not go dark.
                    Color.black.opacity(0.52).contentShape(.rect)
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
        // The cards' corner, so the panel and the cards it raises are one family.
        let shape = RoundedRectangle(cornerRadius: ModalCardChrome.radius, style: .continuous)
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
        .modalPanel(in: shape)
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
                .font(.system(.title3, weight: .bold))
                .foregroundStyle(InkColor.primary)
                .lineLimit(1)
            trailing
            Spacer(minLength: 0)
            // The card's round glass ✕; Escape stays the scrim's, which is
            // the layer's own way out (`EscapeLayer.events`).
            ModalCloseButton(label: "Close events", answersEscape: false) { model.eventsPanel = nil }
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
                    Button("Create Event", systemImage: "calendar.badge.plus") {
                        model.openEventEditor(inGuild: guildID)
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.capsule)
                    .tint(Palette.accent)
                    .controlSize(.regular)
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
