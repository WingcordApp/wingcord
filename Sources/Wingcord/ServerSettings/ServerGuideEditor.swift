import SwiftUI
import WingcordCore

// MARK: - Editing the Server Guide
//
// **The opposite of onboarding: a whole-object replace.** Every save sends the
// welcome, every task and every resource — proved by a capture that added one
// task and re-sent both. So this page holds a whole `ServerGuide` and hands it
// back, and there is no arrangement of controls that can send a subset.

struct GuideEditor: View {
    let store: ServerSettingsStore
    var guide: ServerGuide

    @State private var draft: ServerGuide?
    @State private var editingTask: GuideTaskDraft?
    @State private var editingResource: GuideResourceDraft?

    private var working: ServerGuide { draft ?? guide }
    private var isDirty: Bool { draft != nil && draft != guide }

    /// Discord refuses an enabled guide without a welcome and at least three
    /// tasks — its own Review step says so in those words. Stated rather than
    /// enforced by dimming, because the reader needs to know *how many more*.
    private var missing: String? {
        var wants: [String] = []
        if (working.welcome?.message ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            wants.append("a welcome message")
        }
        if working.actions.count < 3 {
            let short = 3 - working.actions.count
            wants.append("\(short) more task\(short == 1 ? "" : "s")")
        }
        return wants.isEmpty ? nil : wants.formatted(.list(type: .and))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            enableCard
            welcomeCard
            tasksCard
            resourcesCard
            saveBar
        }
        .sheet(item: $editingTask) { task in
            GuideTaskSheet(task: task, store: store) { edited in
                var next = working
                if let index = next.actions.firstIndex(where: { $0.id == edited.id }) {
                    next.actions[index] = edited.action
                } else {
                    next.actions.append(edited.action)
                }
                draft = next
            }
        }
        .sheet(item: $editingResource) { resource in
            GuideResourceSheet(resource: resource, store: store) { edited in
                var next = working
                if let index = next.resources.firstIndex(where: { $0.id == edited.id }) {
                    next.resources[index] = edited.resource
                } else {
                    next.resources.append(edited.resource)
                }
                draft = next
            }
        }
    }

    private var enableCard: some View {
        SettingsGroup {
            SettingsCard {
                SettingsToggle(
                    title: "Server Guide is enabled",
                    isOn: Binding(
                        get: { guide.isEnabled },
                        set: { isOn in
                            // The whole guide goes with the switch, because the
                            // route takes the whole guide. Sending the current
                            // one rather than the draft: flipping Enable is not
                            // a way to save half-finished edits.
                            Task { await store.saveServerGuide(guide, isEnabled: isOn) }
                        }
                    )
                )
                .disabled(!guide.isEnabled && missing != nil)
            }
            if let missing {
                SettingsFootnote(
                    "Before this can be turned on, the guide needs \(missing).",
                    symbolName: "exclamationmark.circle"
                )
            }
        }
    }

    private var welcomeCard: some View {
        SettingsGroup("Welcome message") {
            SettingsCard {
                GuideWelcomeField(guide: working) { message in
                    var next = working
                    next.welcome = ServerGuide.Welcome(
                        authorIDs: working.welcome?.authorIDs ?? [],
                        message: message
                    )
                    draft = next
                }
            }
            SettingsFootnote(
                "Write [@username] where each new member's own name should go. "
                    + "It stays literal here and is substituted when they read it."
            )
        }
    }

    private var tasksCard: some View {
        SettingsGroup("New member tasks — \(working.actions.count)") {
            SettingsCard {
                ForEach(Array(working.actions.enumerated()), id: \.element.id) { index, action in
                    if index > 0 { CardDivider() }
                    ObjectRow(
                        title: action.title,
                        subtitle: taskSubtitle(action)
                    ) {
                        Text(action.emojiName ?? "✓")
                            .font(.system(size: 14))
                            .frame(width: 28, height: 28)
                    } trailing: {
                        HStack(spacing: 2) {
                            RowIconButton(symbolName: "pencil", label: "Edit task") {
                                editingTask = GuideTaskDraft(action)
                            }
                            RowIconButton(
                                symbolName: "trash",
                                label: "Remove task",
                                role: .destructive
                            ) {
                                var next = working
                                next.actions.removeAll { $0.id == action.id }
                                draft = next
                            }
                        }
                    }
                }
                CardDivider()
                SettingsActionRow("Add a task", actionTitle: "Add") {
                    editingTask = GuideTaskDraft(nextID: (working.actions.map(\.id).max() ?? -1) + 1)
                }
            }
            SettingsFootnote("Discord asks for three to five. Five is the maximum.")
        }
    }

    private var resourcesCard: some View {
        SettingsGroup("Resource pages — \(working.resources.count)") {
            SettingsCard {
                ForEach(Array(working.resources.enumerated()), id: \.element.id) { index, resource in
                    if index > 0 { CardDivider() }
                    ObjectRow(
                        title: resource.title,
                        subtitle: store.channelName(resource.channelID).map { "#\($0)" }
                    ) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 12))
                            .foregroundStyle(Ink.secondary)
                            .frame(width: 28, height: 28)
                    } trailing: {
                        HStack(spacing: 2) {
                            RowIconButton(symbolName: "pencil", label: "Edit resource") {
                                editingResource = GuideResourceDraft(resource)
                            }
                            RowIconButton(
                                symbolName: "trash",
                                label: "Remove resource",
                                role: .destructive
                            ) {
                                var next = working
                                next.resources.removeAll { $0.id == resource.id }
                                draft = next
                            }
                        }
                    }
                }
                CardDivider()
                SettingsActionRow("Add a resource", actionTitle: "Add") {
                    editingResource = GuideResourceDraft(
                        nextID: (working.resources.map(\.id).max() ?? -1) + 1
                    )
                }
            }
            SettingsFootnote(
                "Read-only channels turned into pages. Seven is the maximum, and "
                    + "they leave the ordinary channel list."
            )
        }
    }

    private func taskSubtitle(_ action: ServerGuide.Action) -> String {
        var parts: [String] = []
        if let name = store.channelName(action.channelID) { parts.append("#\(name)") }
        // 0 is "visits the channel", 1 is "sends a message" — checked against
        // Discord's own copy, see §SM.12.
        parts.append(action.kind == .write ? "sends a message" : "visits the channel")
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var saveBar: some View {
        if isDirty {
            HStack(spacing: Spacing.base) {
                Spacer()
                Button("Revert") { draft = nil }
                    .buttonStyle(.plain)
                    .font(.system(.caption))
                    .foregroundStyle(Ink.tertiary)
                Button("Save guide") {
                    Task {
                        await store.saveServerGuide(working, isEnabled: guide.isEnabled)
                        draft = nil
                    }
                }
                .buttonStyle(.glassProminent)
            }
            .padding(.top, Spacing.margin)
        }
    }
}

/// Its own view so the draft text survives redraws.
private struct GuideWelcomeField: View {
    var guide: ServerGuide
    var commit: (String) -> Void

    @State private var text = ""

    var body: some View {
        EditableTextBlock(
            placeholder: "Hey [@username], glad you're here!",
            text: $text,
            committed: guide.welcome?.message ?? "",
            characterLimit: 300
        ) {
            commit(text)
        }
        .task(id: guide.welcome?.message) { text = guide.welcome?.message ?? "" }
    }
}

// MARK: - Task and resource sheets

struct GuideTaskDraft: Identifiable, Hashable {
    var id: Int
    var title: String
    var channelID: ChannelID?
    var kind: ServerGuide.Action.Kind
    var emojiName: String?

    init(nextID: Int) {
        id = nextID
        title = ""
        channelID = nil
        kind = .read
        emojiName = nil
    }

    init(_ action: ServerGuide.Action) {
        id = action.id
        title = action.title
        channelID = action.channelID
        kind = action.kind
        emojiName = action.emojiName
    }

    var action: ServerGuide.Action {
        ServerGuide.Action(
            id: id,
            channelID: channelID ?? ChannelID(rawValue: 0),
            kind: kind,
            title: title,
            detail: nil,
            emojiName: emojiName
        )
    }
}

struct GuideTaskSheet: View {
    var task: GuideTaskDraft
    let store: ServerSettingsStore
    var commit: (GuideTaskDraft) -> Void

    @State private var working: GuideTaskDraft

    init(task: GuideTaskDraft, store: ServerSettingsStore, commit: @escaping (GuideTaskDraft) -> Void) {
        self.task = task
        self.store = store
        self.commit = commit
        _working = State(initialValue: task)
    }

    var body: some View {
        SheetFrame(
            title: "Task",
            confirmTitle: "Save",
            canConfirm: !working.title.trimmingCharacters(in: .whitespaces).isEmpty
                && working.channelID != nil
        ) {
            commit(working)
        } content: {
            SheetField(title: "What should the new member do?", isRequired: true) {
                TextField("Post a photo of your pet", text: $working.title)
                    .textFieldStyle(.roundedBorder)
            }

            SheetField(
                title: "Where should they do it?",
                // Discord's own requirement, and it is why the picker is
                // filtered rather than offering every channel and failing.
                detail: "Channels must be viewable by @everyone.",
                isRequired: true
            ) {
                Picker("", selection: $working.channelID) {
                    Text("Choose a channel").tag(ChannelID?.none)
                    ForEach(store.textChannels.filter(\.isPublic)) { channel in
                        Text("#\(channel.name)").tag(ChannelID?.some(channel.id))
                    }
                }
                .labelsHidden()
            }

            SheetField(title: "This task is complete when", isRequired: true) {
                Picker("", selection: $working.kind) {
                    Text("The member visits the channel").tag(ServerGuide.Action.Kind.read)
                    Text("The member sends a message in it").tag(ServerGuide.Action.Kind.write)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            SheetField(title: "Emoji") {
                TextField("👋", text: Binding(
                    get: { working.emojiName ?? "" },
                    set: { working.emojiName = $0.isEmpty ? nil : $0 }
                ))
                .textFieldStyle(.roundedBorder)
            }
        }
    }
}

struct GuideResourceDraft: Identifiable, Hashable {
    var id: Int
    var title: String
    var channelID: ChannelID?
    var detail: String

    init(nextID: Int) {
        id = nextID
        title = ""
        channelID = nil
        detail = ""
    }

    init(_ resource: ServerGuide.Resource) {
        id = resource.id
        title = resource.title
        channelID = resource.channelID
        detail = resource.detail ?? ""
    }

    var resource: ServerGuide.Resource {
        ServerGuide.Resource(
            id: id,
            channelID: channelID ?? ChannelID(rawValue: 0),
            title: title,
            detail: detail.isEmpty ? nil : detail
        )
    }
}

struct GuideResourceSheet: View {
    var resource: GuideResourceDraft
    let store: ServerSettingsStore
    var commit: (GuideResourceDraft) -> Void

    @State private var working: GuideResourceDraft

    init(
        resource: GuideResourceDraft,
        store: ServerSettingsStore,
        commit: @escaping (GuideResourceDraft) -> Void
    ) {
        self.resource = resource
        self.store = store
        self.commit = commit
        _working = State(initialValue: resource)
    }

    var body: some View {
        SheetFrame(
            title: "Resource page",
            confirmTitle: "Save",
            canConfirm: !working.title.trimmingCharacters(in: .whitespaces).isEmpty
                && working.channelID != nil
        ) {
            commit(working)
        } content: {
            SheetField(
                title: "Channel",
                detail: "Only channels that are read-only for @everyone.",
                isRequired: true
            ) {
                Picker("", selection: $working.channelID) {
                    Text("Choose a channel").tag(ChannelID?.none)
                    ForEach(store.textChannels) { channel in
                        Text("#\(channel.name)").tag(ChannelID?.some(channel.id))
                    }
                }
                .labelsHidden()
            }

            SheetField(title: "Name", isRequired: true) {
                TextField("Rules", text: $working.title)
                    .textFieldStyle(.roundedBorder)
            }

            SheetField(title: "Description") {
                TextField("Rules for the server", text: $working.detail, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)
            }
        }
    }
}
