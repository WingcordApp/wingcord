import SwiftUI
import WingcordCore

/// What the reader can do about an event, at the foot of its card and of its
/// page — Discord's `428978.Zq` after the "…": Copy Link; Join for one on in a
/// room; Interested for one not on yet; Start for an organiser near its time;
/// End for an organiser of one on somewhere else.
struct EventActionBar: View {
    var event: ScheduledEvent
    /// The date shown — the series' current one, or the one chosen.
    var occurrence: UInt64?

    @Environment(AppModel.self) private var model
    @State private var hasCopied = false
    /// The capsules' height, read off Copy Link, for the ⋯ beside it.
    @State private var capsuleHeight: CGFloat?
    /// The date whose Interested asked "the series, or this one?".
    @State private var askedDate: UInt64?
    @State private var confirmation: EventConfirmation?

    var body: some View {
        let isActive = event.status == .active
        let isExternal = event.location.externalLocation != nil
        let canManage = model.canManage(event)
        HStack(spacing: Spacing.base) {
            EventMoreMenu(event: event, occurrence: occurrence, side: capsuleHeight, confirm: { confirmation = $0 })
            copyButton
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { capsuleHeight = $0 }
            if isActive, !isExternal { joinButton }
            if !isActive { interestedButton }
            // Discord offers Start from fifteen minutes before, never for a
            // cancelled date — and a stage needs an instance this client does
            // not make.
            if !isActive, canManage, isStartable, event.exception(for: occurrence)?.isCanceled != true {
                Button { confirmation = .start } label: { EventActionLabel(title: "Start") }
                    .buttonStyle(.glassProminent)
                    .tint(Palette.accent)
            }
            if isActive, canManage, isExternal {
                Button { confirmation = .end } label: { EventActionLabel(title: "End Event") }
                    .buttonStyle(.glass)
            }
        }
        // Glass capsules of one height, every one — the app's button (Alex,
        // 2026-10-27, screenshots 35–36: a squat ⋯ beside a flat Copy Link).
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .eventConfirmation($confirmation, for: event)
    }

    private var isStartable: Bool {
        if case .stage = event.location { return false }
        return event.startsAt <= .now.addingTimeInterval(15 * 60)
    }

    // MARK: The buttons

    /// Discord's card copies the plain event link, and says so for a second.
    private var copyButton: some View {
        Button {
            model.copyEventLink(event, occurrence: nil)
            hasCopied = true
        } label: {
            EventActionLabel(title: hasCopied ? "Copied" : "Copy Link", systemImage: hasCopied ? "checkmark" : "link")
        }
        .buttonStyle(.glass)
        .disabled(hasCopied)
        .task(id: hasCopied) {
            guard hasCopied else { return }
            try? await Task.sleep(for: .seconds(1))
            hasCopied = false
        }
    }

    /// Into the room — or to it, for a reader already there.
    private var joinButton: some View {
        let channelID = event.location.channelID
        let canJoin = channelID.map(model.permissionGate.canJoinVoice) ?? false
        let title: String = if !canJoin {
            "Channel Locked"
        } else if channelID == model.connectedVoiceChannelID {
            "Go To Channel"
        } else if case .stage = event.location {
            "Listen In"
        } else {
            "Join"
        }
        return Button { model.joinEventRoom(event) } label: { EventActionLabel(title: title) }
            .buttonStyle(.glassProminent)
            .tint(Palette.presenceOnline)
            .disabled(!canJoin)
    }

    private var interestedButton: some View {
        let isInterested = model.isInterested(in: event.id, at: occurrence)
        let button = Button {
            switch model.interestStep(for: event, at: occurrence) {
            case .ask(let date):
                askedDate = date
            case let step:
                model.apply(step, to: event)
            }
        } label: {
            EventActionLabel(title: "Interested", systemImage: isInterested ? "checkmark" : "bell")
        }
        return Group {
            if isInterested {
                button.buttonStyle(.glassProminent).tint(Palette.presenceOnline)
            } else {
                button.buttonStyle(.glass)
            }
        }
        .accessibilityAddTraits(isInterested ? .isSelected : [])
        .popover(
            isPresented: Binding(get: { askedDate != nil }, set: { if !$0 { askedDate = nil } }),
            arrowEdge: .bottom
        ) {
            if let askedDate {
                EventSeriesChoice(event: event, occurrence: askedDate) { self.askedDate = nil }
            }
        }
    }
}

/// One button's words, its glyph set inline in them — so every capsule in
/// the bar is one text line tall, as the ⋯ menu beside them is. A `Label`'s
/// symbol stood a point and a half above the line and made its capsule
/// taller than the menu, which AppKit draws at the small control's own
/// height whatever its label says (Alex, 2026-10-27: "the second pill bigger").
struct EventActionLabel: View {
    var title: String
    var systemImage: String?

    var body: some View {
        if let systemImage {
            Text("\(Image(systemName: systemImage)) \(title)")
        } else {
            Text(title)
        }
    }
}

/// "The whole series, or this date?" — Discord's dialog (`666394`), as a
/// popover off the button that asked. Its title turns to "not interested"
/// when the reader is in the whole series, and each row writes at once.
/// Asked by the event card's Interested too.
struct EventSeriesChoice: View {
    var event: ScheduledEvent
    var occurrence: UInt64
    var close: () -> Void

    @Environment(AppModel.self) private var model

    var body: some View {
        let inSeries = model.eventAnswers[event.id]?.series == .interested
        VStack(alignment: .leading, spacing: 0) {
            Text(inSeries ? "I am not interested in..." : "I am interested in...")
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(Ink.primary)
                .padding(.horizontal, Spacing.snug)
                .padding(.top, Spacing.base)
                .padding(.bottom, Spacing.tight)
            FlyoutRow(title: "All events in this series", symbolName: "repeat") { pick(wholeSeries: true) }
            FlyoutRow(title: "Only this event", symbolName: "calendar") { pick(wholeSeries: false) }
        }
        .padding(.vertical, Spacing.tight)
        .frame(width: 260)
    }

    private func pick(wholeSeries: Bool) {
        model.apply(model.pickedInterest(for: event, occurrence: occurrence, wholeSeries: wholeSeries), to: event)
        close()
    }
}

// MARK: - The "…"

/// Discord's event menu (`399893`), in its order: Add to Calendar, Start,
/// Edit, Cancel, Restore, Copy Event Link, and — on a date in a series' list —
/// Mark as Interested, then the ids for a reader in developer mode.
///
/// **A `Menu`**, the inbox overflow's reasoning: its items are built when it
/// opens, so a card at rest pays for one glyph.
struct EventMoreMenu: View {
    var event: ScheduledEvent
    var occurrence: UInt64?
    /// A date in "Events in series", whose menu answers for that date.
    var isSeriesDate = false
    /// The circle's diameter: the capsules' height beside it, when the bar
    /// has measured it.
    var side: CGFloat? = nil
    var confirm: (EventConfirmation) -> Void

    @Environment(AppModel.self) private var model

    var body: some View {
        // **Its own glass, at its neighbours' height.** A `Menu` in a glass
        // button style is AppKit's pop-up, drawn at the small control's own
        // 19 points whatever its label says — a point and a half under the
        // SwiftUI capsules beside it (Alex, 2026-10-27, screenshot 36). Plain,
        // the menu draws this label as given, so the circle is the bar's.
        if let side {
            Menu {
                items
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(InkColor.primary)
                    .frame(width: side, height: side)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .contentShape(.circle)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More options")
            .accessibilityLabel(Text("More options"))
        } else {
            Menu {
                items
            } label: {
                Text(Image(systemName: "ellipsis"))
                    .fontWeight(.semibold)
            }
            .menuStyle(.button)
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .menuIndicator(.hidden)
            .help("More options")
            .accessibilityLabel(Text("More options"))
        }
    }

    @ViewBuilder
    private var items: some View {
        let isActive = event.status == .active
        let canManage = model.canManage(event)
        let date = event.rule == nil ? nil : occurrence
        let dateIsCanceled = date.flatMap(event.exception(for:))?.isCanceled == true

        if !isActive {
            Button("Add to Calendar", systemImage: "calendar.badge.plus") { model.addEventToCalendar(event) }
        }
        if !isSeriesDate, canManage, !isActive, !hasActiveEventInRoom, !isStage {
            Button("Start Event", systemImage: "play") { confirm(.start) }
        }
        if canManage {
            Button("Edit Event", systemImage: "pencil") {
                model.openEventEditor(inGuild: event.guildID, event: event)
            }
        }
        if canManage, offersCancel(isActive: isActive, date: date) {
            if let date {
                Menu("Cancel Event", systemImage: "xmark.circle") {
                    Button("Cancel this Event", role: .destructive) { confirm(.cancelDate(date)) }
                        .disabled(dateIsCanceled)
                    Button("Cancel all Events in this Series", role: .destructive) { confirm(.cancel(wholeSeries: true)) }
                }
            } else {
                Button("Cancel Event", systemImage: "xmark.circle", role: .destructive) {
                    confirm(.cancel(wholeSeries: event.rule != nil))
                }
            }
        }
        if canManage, let date, dateIsCanceled {
            Button("Restore Event", systemImage: "arrow.uturn.backward") {
                model.sessionController.setEventDate(date, of: event, canceled: false)
            }
        }
        if let date {
            Menu("Copy Event Link", systemImage: "link") {
                Button("Copy Link for Only this Event") { model.copyEventLink(event, occurrence: date) }
                Button("Copy Link for all Events") { model.copyEventLink(event, occurrence: nil) }
            }
        } else {
            Button("Copy Event Link", systemImage: "link") { model.copyEventLink(event, occurrence: nil) }
        }
        if isSeriesDate, let date, !dateIsCanceled {
            let answers = model.eventAnswers[event.id]
            Menu(
                model.isInterested(in: event.id, at: date) ? "Mark as Not Interested" : "Mark as Interested",
                systemImage: "bell"
            ) {
                Button("Only this event") {
                    model.apply(model.pickedInterest(for: event, occurrence: date, wholeSeries: false), to: event)
                }
                Button("All events in this series") {
                    model.apply(model.pickedInterest(for: event, occurrence: date, wholeSeries: true), to: event)
                }
                // Discord's own rule: a date answered on its own is answered
                // there, not through the series.
                .disabled(answers?.dates[date] != nil)
            }
        }
        if AppSettings.shared.developerMode {
            Divider()
            Button("Copy Event ID", systemImage: "number") { copy(String(event.id)) }
            if let date {
                Button("Copy Recurrence ID", systemImage: "number") { copy(String(date)) }
            }
        }
    }

    private var isStage: Bool {
        if case .stage = event.location { return true }
        return false
    }

    /// Another event already on in the same room — Discord offers no second
    /// Start there.
    private var hasActiveEventInRoom: Bool {
        guard let channelID = event.location.channelID else { return false }
        return model.scheduledEvents[event.guildID]?.contains {
            $0.id != event.id && $0.status == .active && $0.location.channelID == channelID
        } == true
    }

    /// Discord's rule: an event on now cannot be cancelled, except a date of
    /// a series that has not started yet.
    private func offersCancel(isActive: Bool, date: UInt64?) -> Bool {
        guard isActive else { return true }
        guard let date else { return false }
        return event.span(of: date).start > .now
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Confirmations

/// The acts that ask first — each with Discord's own words.
enum EventConfirmation: Equatable {
    case start
    case end
    /// The whole event — every date, for a series.
    case cancel(wholeSeries: Bool)
    /// One date of a series.
    case cancelDate(UInt64)

    var title: String {
        switch self {
        case .start: "Start Event"
        case .end: "End Event"
        case .cancel, .cancelDate: "Cancel Event?"
        }
    }

    /// The card's symbol, and its act's.
    var symbolName: String {
        switch self {
        case .start: "play.fill"
        case .end: "stop.fill"
        case .cancel, .cancelDate: "calendar.badge.minus"
        }
    }

    var message: String {
        switch self {
        case .start: "You are about to start this event"
        case .end: "Are you sure you want to end the event?"
        case .cancel(wholeSeries: true):
            "Are you sure you want to cancel this event? Canceling this event will also cancel all events in this series."
        case .cancel, .cancelDate: "Are you sure you want to cancel this event?"
        }
    }

    var confirmTitle: String {
        switch self {
        case .start: "Start Event"
        case .end: "Yes, end the event"
        case .cancel(wholeSeries: true): "Cancel all Events"
        case .cancel, .cancelDate: "Cancel Event"
        }
    }

    var isDestructive: Bool {
        switch self {
        case .start: false
        case .end, .cancel, .cancelDate: true
        }
    }
}

extension View {
    /// Asks before an event is started, ended or cancelled, and does it.
    func eventConfirmation(_ confirmation: Binding<EventConfirmation?>, for event: ScheduledEvent) -> some View {
        modifier(EventConfirmationDialog(confirmation: confirmation, event: event))
    }
}

private struct EventConfirmationDialog: ViewModifier {
    @Binding var confirmation: EventConfirmation?
    var event: ScheduledEvent

    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.modal(
            isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }),
            style: .alert
        ) {
            if let asked = confirmation {
                ModalAlert(
                    hero: .symbol(asked.symbolName),
                    title: asked.title,
                    message: Text(asked.message),
                    actions: [
                        .cancel("Never Mind"),
                        // Chosen, so the act's colour; a cancellation cannot be
                        // taken back, so it takes no Return (D11b).
                        .act(asked.confirmTitle, symbol: asked.symbolName, irreversible: asked.isDestructive) {
                            perform(asked)
                        },
                    ]
                )
            }
        }
    }

    private func perform(_ asked: EventConfirmation) {
        let session = model.sessionController
        switch asked {
        case .start: session.setEventStatus(event, to: .active)
        case .end: session.setEventStatus(event, to: .completed)
        case .cancel: session.deleteScheduledEvent(event)
        case .cancelDate(let date): session.setEventDate(date, of: event, canceled: true)
        }
    }
}
