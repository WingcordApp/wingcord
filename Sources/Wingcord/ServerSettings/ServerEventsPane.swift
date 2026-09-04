import AppKit
import SwiftUI
import WingcordCore

// MARK: - Events
//
// A list, and one sheet that both creates and edits.
//
// **Not a three-step wizard.** Discord's is Location → Event Info → Review, and
// the reason it is three steps is that the first choice changes what the second
// asks for — a voice event needs a channel and an external one needs an address.
// On a 520-point sheet with room for the whole form at once, three steps would
// be three screens' worth of paging for six fields, and the Review step reviews
// a form the reader can already see. So the location picker is at the top and
// the field under it changes with it, which is the same conditional expressed
// without the paging.

struct EventsPane: View {
    let store: ServerSettingsStore

    @State private var composing = false
    @State private var editing: ScheduledEvent?
    @State private var cancelling: ScheduledEvent?
    @State private var deleting: ScheduledEvent?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup {
                SettingsCard {
                    SettingsActionRow(
                        "Create an event",
                        help: "Members can say they are interested and get a reminder.",
                        actionTitle: "Create"
                    ) {
                        composing = true
                    }
                }
            }

            LoadableContent(
                store.events,
                isEmpty: \.isEmpty,
                empty: { EmptyRow(message: "No events scheduled.", symbolName: "calendar") }
            ) { events in
                let upcoming = events.filter { $0.status.isLive }.sorted { $0.startsAt < $1.startsAt }
                let past = events.filter { !$0.status.isLive }.sorted { $0.startsAt > $1.startsAt }
                section("Upcoming — \(upcoming.count)", events: upcoming)
                section("Ended and cancelled — \(past.count)", events: past)
            }
        }
        .sheet(isPresented: $composing) {
            EventSheet(store: store, existing: nil)
        }
        .sheet(item: $editing) { event in
            EventSheet(store: store, existing: event)
        }
    }

    @ViewBuilder
    private func section(_ title: String, events: [ScheduledEvent]) -> some View {
        if !events.isEmpty {
            SettingsGroup(title) {
                SettingsCard {
                    ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                        if index > 0 { CardDivider() }
                        row(event)
                    }
                }
            }
        }
    }

    private func row(_ event: ScheduledEvent) -> some View {
        ObjectRow(
            title: event.name,
            subtitle: subtitle(event),
            badge: event.interestedCount.map { $0 == 1 ? "1 interested" : "\($0) interested" }
        ) {
            RemoteImage(url: event.coverURL, side: 40) {
                SettingsSurface.controlTrough.overlay {
                    Image(systemName: event.location.symbolName)
                        .font(.system(size: 13))
                        .foregroundStyle(Ink.tertiary)
                }
            }
            .frame(width: 56, height: 32)
            .clipShape(.rect(cornerRadius: 6, style: .continuous))
        } trailing: {
            HStack(spacing: 2) {
                RowIconButton(symbolName: "link", label: "Copy a link to \(event.name)") {
                    Task { await copyLink(event) }
                }
                // A completed or cancelled event refuses both routes, so the row
                // offers neither rather than offering them and answering 400.
                if event.status.isLive {
                    RowIconButton(symbolName: "pencil", label: "Edit \(event.name)") {
                        editing = event
                    }
                    RowIconButton(
                        symbolName: "xmark.circle",
                        label: "Cancel \(event.name)"
                    ) {
                        cancelling = event
                    }
                }
                RowIconButton(
                    symbolName: "trash",
                    label: "Delete \(event.name)",
                    role: .destructive
                ) {
                    deleting = event
                }
            }
        }
        // **Cancel and delete are different acts and are offered separately.**
        // Cancelling leaves the event where everybody who said they were coming
        // can see that it is off; deleting takes it away with no trace. A page
        // that only had "delete" would quietly make the first one impossible.
        .destructiveConfirmation(
            isPresented: Binding(
                get: { cancelling?.id == event.id },
                set: { if !$0 { cancelling = nil } }
            ),
            title: "Cancel \(event.name)?",
            message: "It stays visible, marked cancelled, so the people who were "
                + "interested find out.",
            confirmTitle: "Cancel event"
        ) {
            Task { await store.cancelEvent(event.id) }
        }
        .destructiveConfirmation(
            isPresented: Binding(
                get: { deleting?.id == event.id },
                set: { if !$0 { deleting = nil } }
            ),
            title: "Delete \(event.name)?",
            message: "It disappears from everybody's list with no notice. To tell "
                + "people it is off, cancel it instead.",
            confirmTitle: "Delete"
        ) {
            Task { await store.deleteEvent(event.id) }
        }
    }

    private func subtitle(_ event: ScheduledEvent) -> String {
        var parts: [String] = []
        parts.append(event.startsAt.formatted(date: .abbreviated, time: .shortened))
        switch event.location {
        case .stage(let id), .voice(let id):
            if let name = store.channelName(id) { parts.append("#\(name)") }
        case .external(let place):
            if !place.isEmpty { parts.append(place) }
        case .unrecognised:
            parts.append("Somewhere this client does not recognise")
        }
        if let recurrence = event.recurrence {
            parts.append(recurrence.title(startingAt: event.startsAt).lowercased())
        }
        if !event.status.isLive { parts.append(event.status.title.lowercased()) }
        return parts.joined(separator: " · ")
    }

    /// The share link.
    ///
    /// **An event's link is an ordinary channel invite with the event id on the
    /// end** — the capture's share sheet showed
    /// `https://discord.gg/{code}?event={id}`, and the request behind it was a
    /// plain `POST /channels/{id}/invites`. So this makes one, on the event's
    /// own channel where it has one and on the first text channel otherwise,
    /// which is what the reference does.
    private func copyLink(_ event: ScheduledEvent) async {
        let channelID = event.location.channelID ?? store.textChannels.first?.id
        guard let channelID else { return }
        guard let code = await store.inviteCode(in: channelID) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            "https://discord.gg/\(code)?event=\(event.id)",
            forType: .string
        )
    }
}

// MARK: - Creating and editing

struct EventSheet: View {
    let store: ServerSettingsStore
    var existing: ScheduledEvent?

    @State private var name = ""
    @State private var detail = ""
    @State private var kind: LocationKind = .external
    @State private var channelID: ChannelID?
    @State private var place = ""
    @State private var startsAt = Date().addingTimeInterval(3600)
    @State private var hasEnd = false
    @State private var endsAt = Date().addingTimeInterval(7200)
    @State private var recurrence: Recurrence?
    @State private var cover: ImageData?
    @State private var coverName: String?

    private enum LocationKind: String, CaseIterable, Identifiable {
        case stage, voice, external
        var id: Self { self }

        var title: String {
            switch self {
            case .stage: "Stage channel"
            case .voice: "Voice channel"
            case .external: "Somewhere else"
            }
        }

        var detail: String {
            switch self {
            case .stage: "Built for larger events — hand raise, and everybody muted by default."
            case .voice: "Voice, video, screen share and Go Live."
            case .external: "A text channel, a link, or a place in the world."
            }
        }
    }

    private var isNew: Bool { existing == nil }

    var body: some View {
        SheetFrame(
            title: isNew ? "Create an event" : "Edit event",
            confirmTitle: isNew ? "Create" : "Save",
            canConfirm: canConfirm,
            confirm: commit
        ) {
            SheetField(title: "Where", isRequired: true) {
                VStack(alignment: .leading, spacing: Spacing.base) {
                    ForEach(LocationKind.allCases) { candidate in
                        let channels = channels(for: candidate)
                        LocationChoice(
                            title: candidate.title,
                            detail: channels.isEmpty && candidate != .external
                                ? "There are no available channels."
                                : candidate.detail,
                            isSelected: kind == candidate,
                            // A stage option on a server with no stage channel
                            // is a control that cannot work. Discord draws it
                            // dimmed with that same sentence; §5.5 agrees.
                            isEnabled: candidate == .external || !channels.isEmpty
                        ) {
                            kind = candidate
                            if candidate != .external { channelID = channels.first?.id }
                        }
                    }
                }
            }

            if kind == .external {
                SheetField(title: "Location", isRequired: true) {
                    TextField("Where should people go?", text: $place)
                        .textFieldStyle(.roundedBorder)
                }
            } else {
                SheetField(title: "Channel", isRequired: true) {
                    Picker("", selection: $channelID) {
                        ForEach(channels(for: kind)) { channel in
                            Text("#\(channel.name)").tag(ChannelID?.some(channel.id))
                        }
                    }
                    .labelsHidden()
                }
            }

            SheetField(title: "Name", isRequired: true) {
                TextField("What is happening?", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            SheetField(title: "Description") {
                TextField("", text: $detail, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...5)
            }

            SheetField(title: "Starts") {
                DatePicker("", selection: $startsAt)
                    .labelsHidden()
                    .datePickerStyle(.compact)
            }

            SheetField(
                title: "Ends",
                // An external event has no channel to empty, so Discord requires
                // an end time for one and makes it optional for the other two.
                detail: kind == .external
                    ? "Required for an event that is not in a channel."
                    : "Optional — a channel event ends when everybody leaves."
            ) {
                HStack(spacing: Spacing.snug) {
                    if kind != .external {
                        Toggle("", isOn: $hasEnd)
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                    }
                    DatePicker("", selection: $endsAt)
                        .labelsHidden()
                        .datePickerStyle(.compact)
                        .disabled(kind != .external && !hasEnd)
                }
            }

            SheetField(title: "Repeats") {
                Picker("", selection: $recurrence) {
                    Text("Does not repeat").tag(Recurrence?.none)
                    ForEach(Recurrence.choices(startingAt: startsAt), id: \.self) { choice in
                        Text(choice.title(startingAt: startsAt)).tag(Recurrence?.some(choice))
                    }
                    // Only where the event already has one this client cannot
                    // express — never offered to a new event.
                    if recurrence == .unrecognised {
                        Text("Custom (kept as it is)").tag(Recurrence?.some(.unrecognised))
                    }
                }
                .labelsHidden()
            }

            SheetField(
                title: "Cover image",
                detail: "Recommended 800×320. Optional."
            ) {
                HStack {
                    Text(coverName ?? (existing?.imageHash == nil ? "No image" : "Current image kept"))
                        .font(SettingsType.rowLabel)
                        .foregroundStyle(cover == nil ? Ink.tertiary : Ink.primary)
                        .lineLimit(1)
                    Spacer()
                    Button("Browse…") {
                        guard let file = ExpressionUpload.pickFile(types: [.png, .jpeg, .gif])
                        else { return }
                        cover = ImageData(mimeType: file.contentType, bytes: file.bytes)
                        coverName = file.filename
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }
            }
        }
        .task { adopt() }
    }

    private func channels(for kind: LocationKind) -> [ServerSettingsStore.ChannelSummary] {
        switch kind {
        case .stage: store.channels.filter { $0.kind == .stage }
        case .voice: store.voiceChannels
        case .external: []
        }
    }

    private var canConfirm: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard startsAt > .now || !isNew else { return false }
        switch kind {
        case .external:
            // Both required, and the end has to be after the start — Discord
            // refuses either, and saying so before the request is better than a
            // 400 with the field named in Discord's words.
            return !place.trimmingCharacters(in: .whitespaces).isEmpty && endsAt > startsAt
        case .stage, .voice:
            return channelID != nil && (!hasEnd || endsAt > startsAt)
        }
    }

    private func adopt() {
        guard let existing else { return }
        name = existing.name
        detail = existing.description ?? ""
        startsAt = existing.startsAt
        if let end = existing.endsAt {
            endsAt = end
            hasEnd = true
        }
        recurrence = existing.recurrence
        switch existing.location {
        case .stage(let id):
            kind = .stage
            channelID = id
        case .voice(let id):
            kind = .voice
            channelID = id
        case .external(let value):
            kind = .external
            place = value
        case .unrecognised:
            kind = .external
        }
    }

    private func commit() {
        let location: ScheduledEvent.Location
        switch kind {
        case .external:
            location = .external(place.trimmingCharacters(in: .whitespaces))
        case .stage:
            guard let channelID else { return }
            location = .stage(channelID)
        case .voice:
            guard let channelID else { return }
            location = .voice(channelID)
        }
        let end: Date? = (kind == .external || hasEnd) ? endsAt : nil
        let title = name.trimmingCharacters(in: .whitespaces)
        let blurb = detail.isEmpty ? nil : detail

        Task {
            if let existing {
                await store.saveEvent(
                    existing.id,
                    name: title,
                    description: blurb,
                    location: location,
                    startsAt: startsAt,
                    endsAt: end,
                    recurrence: recurrence,
                    cover: cover
                )
            } else {
                await store.createEvent(
                    name: title,
                    description: blurb,
                    location: location,
                    startsAt: startsAt,
                    endsAt: end,
                    recurrence: recurrence,
                    cover: cover
                )
            }
        }
    }
}

private struct LocationChoice: View {
    var title: String
    var detail: String
    var isSelected: Bool
    var isEnabled: Bool
    var choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack(alignment: .top, spacing: Spacing.snug) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(Ink.tertiary))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(.subheadline, weight: .medium))
                        .foregroundStyle(isEnabled ? AnyShapeStyle(Ink.primary) : AnyShapeStyle(Ink.tertiary))
                    Text(detail)
                        .font(.system(.caption))
                        .foregroundStyle(Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}
