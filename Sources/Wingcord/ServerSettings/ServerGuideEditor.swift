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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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

    private var welcomeCard: some View {
        SettingsGroup("Welcome Sign") {
            Text("Tell new members what\u{2019}s special about your community and why you\u{2019}re excited to see them!")
                .font(SettingsType.rowSubtitle)
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, Spacing.snug)
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
        }
    }

    private var tasksCard: some View {
        SettingsGroup("New Member To Do\u{2019}s") {
            Text("Set 3-5 tasks for your new members to do. Get them to \(Text("talk and engage in your channels.").bold())")
                .font(SettingsType.rowSubtitle)
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, Spacing.snug)
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
                                label: "Remove",
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
        }
    }

    private var resourcesCard: some View {
        SettingsGroup("Resource Pages") {
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text("Turn read-only channels into fancy resource pages in your Server Guide. They will no longer appear on the channel list unless you enable All Channels. Resources come with some perks:")
                Text("\u{2022} Members start at the top of pages instead of the bottom of a message thread")
                Text("\u{2022} Chat bars and avatars are removed so it looks cleaner")
                Text("\u{2022} All the content, embeds, media, and formatting will stay the same")
            }
            .font(SettingsType.rowSubtitle)
            .foregroundStyle(Ink.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, Spacing.snug)
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
                                label: "Remove",
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
        }
    }

    private func taskSubtitle(_ action: ServerGuide.Action) -> String {
        var parts: [String] = []
        if let name = store.channelName(action.channelID) { parts.append("#\(name)") }
        // 0 is "visits the channel", 1 is "sends a message" — checked against
        // Discord's own copy, see §SM.12.
        parts.append(action.kind == .write ? "Member sends a message in the channel" : "Member visits the channel")
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var saveBar: some View {
        if isDirty {
            UnsavedChangesBar(
                reset: { draft = nil },
                save: {
                    let saved = working
                    Task {
                        await store.saveServerGuide(saved, isEnabled: guide.isEnabled)
                        draft = nil
                    }
                }
            )
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
            placeholder: "Hi [@username]! I made this server so that nerds like us could have a safe space to be ourselves. I\u{2019}ve made a bunch of lifelong friends and hope you can find the same thing too. I\u{2019}ve curated some things for you to get started with below:",
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
            title: "Edit task",
            confirmTitle: "Save",
            canConfirm: !working.title.trimmingCharacters(in: .whitespaces).isEmpty
                && working.channelID != nil
        ) {
            commit(working)
        } content: {
            SheetField(title: "What should the new member do?", isRequired: true) {
                TextField("Ex: Post a photo of your pet", text: $working.title)
                    .textFieldStyle(.roundedBorder)
            }

            SheetField(
                title: "Where should they do it?",
                // Discord's own requirement, and it is why the picker is
                // filtered rather than offering every channel and failing.
                detail: "Channels must be viewable by @everyone",
                isRequired: true
            ) {
                Picker("", selection: $working.channelID) {
                    Text("Select").tag(ChannelID?.none)
                    ForEach(store.textChannels.filter(\.isPublic)) { channel in
                        Text("#\(channel.name)").tag(ChannelID?.some(channel.id))
                    }
                }
                .labelsHidden()
            }

            SheetField(title: "This task is complete when:", isRequired: true) {
                Picker("", selection: $working.kind) {
                    Text("Member visits the channel").tag(ServerGuide.Action.Kind.read)
                    Text("Member sends a message in the channel").tag(ServerGuide.Action.Kind.write)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            // The picker — this was a text field with 👋 for a placeholder,
            // the same dead control the onboarding answers had.
            SheetField(title: "Choose Emoji") {
                EmojiSlotButton(
                    emoji: Binding(
                        get: { working.emojiName.map { EmojiRef(name: $0) } },
                        set: { picked in
                            // A task's emoji is a Unicode glyph.
                            guard let picked else { working.emojiName = nil; return }
                            if !picked.isCustom { working.emojiName = picked.name }
                        }
                    ),
                    addLabel: "Choose Emoji",
                    updateLabel: { "Choose Emoji, \($0.name)" }
                )
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
            title: "Edit Resource",
            confirmTitle: "Save",
            canConfirm: !working.title.trimmingCharacters(in: .whitespaces).isEmpty
                && working.channelID != nil
        ) {
            commit(working)
        } content: {
            SheetField(
                title: "Channel",
                detail: "Assigned channel must be readonly for @everyone",
                isRequired: true
            ) {
                Picker("", selection: $working.channelID) {
                    Text("Select").tag(ChannelID?.none)
                    ForEach(store.textChannels) { channel in
                        Text("#\(channel.name)").tag(ChannelID?.some(channel.id))
                    }
                }
                .labelsHidden()
            }

            SheetField(title: "Title", isRequired: true) {
                TextField("Title", text: $working.title)
                    .textFieldStyle(.roundedBorder)
            }

            SheetField(title: "Description") {
                TextField("Ex: Rules for the server", text: $working.detail, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)
            }
        }
    }
}
