import AppKit
import SwiftUI
import WingcordCore

// MARK: - Events
//
// One sheet that both creates and edits, presented from the server's events in
// the main window (`EventEditorHost`) — where Discord's Create Event lives.
//
// **Not a three-step wizard.** Discord's is Location → Event Info → Review, and
// the reason it is three steps is that the first choice changes what the second
// asks for — a voice event needs a channel and an external one needs an address.
// On a 520-point sheet with room for the whole form at once, three steps would
// be three screens' worth of paging for six fields, and the Review step reviews
// a form the reader can already see. So the location picker is at the top and
// the field under it changes with it, which is the same conditional expressed
// without the paging.

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
            case .stage: "Stage Channel"
            case .voice: "Voice Channel"
            case .external: "Somewhere Else"
            }
        }

        var detail: String {
            switch self {
            case .stage: "Great for larger community audio events."
            case .voice: "Hang out with voice, video, screenshare, and Go Live."
            case .external: "Text channel, external link, or in-person location."
            }
        }
    }

    private var isNew: Bool { existing == nil }

    var body: some View {
        SheetFrame(
            title: isNew ? "Create Event" : "Edit Event",
            subtitle: "So no one gets lost on where to go.",
            confirmTitle: isNew ? "Create Event" : "Save Event",
            canConfirm: canConfirm,
            confirm: commit
        ) {
            SheetField(title: "Where is your event?", isRequired: true) {
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
                    TextField("Add a location, link, or something.", text: $place)
                        .textFieldStyle(.roundedBorder)
                }
            } else {
                SheetField(title: "Select a channel", isRequired: true) {
                    Picker("", selection: $channelID) {
                        ForEach(channels(for: kind)) { channel in
                            Text("#\(channel.name)").tag(ChannelID?.some(channel.id))
                        }
                    }
                    .labelsHidden()
                }
            }

            SheetField(title: "Event Topic", isRequired: true) {
                TextField("What\u{2019}s your event?", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            SheetField(title: "Description") {
                TextField("", text: $detail, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...5)
            }

            SheetField(title: "Start Date") {
                DatePicker("", selection: $startsAt)
                    .labelsHidden()
                    .datePickerStyle(.compact)
            }

            // An external event has no channel to empty, so Discord requires
            // an end time for one and makes it optional for the other two.
            SheetField(title: "End Date", isRequired: kind == .external) {
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

            SheetField(title: "Event Frequency") {
                Picker("", selection: $recurrence) {
                    Text("Does not repeat").tag(Recurrence?.none)
                    ForEach(Recurrence.choices(startingAt: startsAt), id: \.self) { choice in
                        Text(choice.title(startingAt: startsAt)).tag(Recurrence?.some(choice))
                    }
                    // Only where the event already has one this client cannot
                    // express — never offered to a new event.
                    if recurrence == .unrecognised {
                        Text(verbatim: "—").tag(Recurrence?.some(.unrecognised))
                    }
                }
                .labelsHidden()
            }

            SheetField(title: "Cover Image") {
                HStack {
                    Text(coverName ?? "")
                        .font(SettingsType.rowLabel)
                        .foregroundStyle(cover == nil ? Ink.tertiary : Ink.primary)
                        .lineLimit(1)
                    Spacer()
                    Button(cover == nil && existing?.imageHash == nil ? "Upload Cover Image" : "Change Image") {
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
                Image(symbol: isSelected ? "largecircle.fill.circle" : "circle")
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
