import SwiftUI
import WingcordCore

// MARK: - Editing onboarding
//
// The two editors behind Onboarding's rows (`OnboardingPane`): Default Channels
// and Questions. Every word is Discord's (`1e901507`, the onboarding pages).
//
// **The route merges per field**, which is what makes these independent saves
// rather than one — see `DiscordREST.setOnboardingChannels`. The channel
// toggles save as they flip; the questions are a draft under Discord's unsaved
// bar, because a question is several fields that make sense only together.

/// Default Channels: the channels every new member is given.
struct OnboardingDefaultChannelsEditor: View {
    let store: ServerSettingsStore
    var onboarding: GuildOnboarding

    var body: some View {
        SettingsGroup {
            SettingsCard {
                if store.textChannels.isEmpty {
                    Text("Add some channels that all users will see!")
                        .font(SettingsType.rowSubtitle)
                        .foregroundStyle(Ink.secondary)
                        .padding(SettingsMetrics.cardContentInset)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(Array(store.textChannels.enumerated()), id: \.element.id) { index, channel in
                    if index > 0 { CardDivider() }
                    let isOn = onboarding.defaultChannelIDs.contains(channel.id)
                    SettingsToggle(
                        title: "#\(channel.name)",
                        isOn: Binding(
                            get: { isOn },
                            set: { wanted in
                                var ids = onboarding.defaultChannelIDs
                                if wanted { ids.append(channel.id) } else { ids.removeAll { $0 == channel.id } }
                                Task { await store.saveOnboardingChannels(ids) }
                            }
                        )
                    )
                }
            }
        }
    }
}

/// Pre-join and Post-join Questions, each a list of question cards, saved
/// together under Discord's unsaved bar.
struct OnboardingQuestionsEditor: View {
    let store: ServerSettingsStore
    var onboarding: GuildOnboarding

    @State private var draft: OnboardingDraft?
    @State private var editing: OnboardingDraft.Prompt?

    private var working: OnboardingDraft { draft ?? OnboardingDraft(onboarding) }
    private var isDirty: Bool { draft != nil && draft != OnboardingDraft(onboarding) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            questions(
                "Pre-join Questions",
                detail: "Members will be asked these questions before they join your server. Use them to assign channels and important roles. Pre-join Questions will also be available on the Channels & Roles page.",
                prompts: working.preJoin,
                isPreJoin: true
            )
            questions(
                "Post-join Questions",
                detail: "Members will be asked these questions after they join your server, on the Channels & Roles page. Use them to assign roles that members can pick later, like vanity roles.",
                prompts: working.postJoin,
                isPreJoin: false
            )
            if isDirty {
                UnsavedChangesBar(
                    canSave: working.isSavable,
                    reset: { draft = nil },
                    save: {
                        let prompts = working.prompts
                        Task {
                            await store.saveOnboardingPrompts(prompts)
                            draft = nil
                        }
                    }
                )
                .padding(.top, Spacing.margin)
            }
        }
        .sheet(item: $editing) { prompt in
            OnboardingPromptSheet(prompt: prompt, store: store) { edited in
                var next = working
                if let index = next.prompts.firstIndex(where: { $0.id == edited.id }) {
                    next.prompts[index] = edited
                } else {
                    next.prompts.append(edited)
                }
                draft = next
            }
        }
    }

    private func questions(
        _ title: String,
        detail: String,
        prompts: [OnboardingDraft.Prompt],
        isPreJoin: Bool
    ) -> some View {
        SettingsGroup(title) {
            Text(detail)
                .font(SettingsType.rowSubtitle)
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, Spacing.snug)
            ForEach(prompts) { prompt in
                questionCard(prompt)
                    .padding(.bottom, Spacing.base)
            }
            Button {
                editing = OnboardingDraft.Prompt(isPreJoin: isPreJoin)
            } label: {
                Label("Add a Question", systemImage: "plus")
                    .font(SettingsType.rowLabel)
            }
            .buttonStyle(.glass)
            .controlSize(.small)
        }
    }

    /// One question as Discord's card shows it: the question, its answers,
    /// and the two switches it carries.
    private func questionCard(_ prompt: OnboardingDraft.Prompt) -> some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: Spacing.snug) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.base) {
                    Text(verbatim: prompt.title)
                        .font(SettingsType.rowTitle)
                        .foregroundStyle(Ink.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    RowIconButton(symbolName: "pencil", label: "Edit") { editing = prompt }
                    RowIconButton(symbolName: "trash", label: "Delete this question", role: .destructive) {
                        var next = working
                        next.prompts.removeAll { $0.id == prompt.id }
                        draft = next
                    }
                }
                AnswerChips(options: prompt.options)
                HStack(spacing: Spacing.margin) {
                    if !prompt.isSingleSelect { flag("Allow multiple answers") }
                    if prompt.isPreJoin, prompt.isRequired { flag("Required") }
                }
            }
            .padding(SettingsMetrics.cardContentInset)
        }
    }

    private func flag(_ text: String) -> some View {
        Label(text, systemImage: "checkmark")
            .font(.system(.caption))
            .foregroundStyle(Ink.secondary)
    }
}

/// A question's answers, each its emoji and its words.
private struct AnswerChips: View {
    var options: [OnboardingDraft.Option]

    var body: some View {
        FlowLayout(spacing: Spacing.tight) {
            ForEach(options) { option in
                HStack(spacing: Spacing.tight) {
                    if let emoji = option.emoji {
                        ExpressionGlyph(emoji: emoji, side: 14)
                    }
                    Text(verbatim: option.title)
                        .font(.system(.caption))
                        .foregroundStyle(Ink.primary)
                }
                .padding(.horizontal, Spacing.snug)
                .padding(.vertical, 4)
                .background(SettingsSurface.controlTrough, in: .capsule)
            }
        }
    }
}

// MARK: - One question

/// A question's own sheet: the question, its answers — each an emoji, its
/// words, and the channels and roles it gives — and its two switches.
struct OnboardingPromptSheet: View {
    var prompt: OnboardingDraft.Prompt
    let store: ServerSettingsStore
    var commit: (OnboardingDraft.Prompt) -> Void

    @State private var working: OnboardingDraft.Prompt

    init(
        prompt: OnboardingDraft.Prompt,
        store: ServerSettingsStore,
        commit: @escaping (OnboardingDraft.Prompt) -> Void
    ) {
        self.prompt = prompt
        self.store = store
        self.commit = commit
        _working = State(initialValue: prompt)
    }

    var body: some View {
        SheetFrame(
            title: prompt.title.isEmpty ? "Add a Question" : prompt.title,
            subtitle: prompt.isPreJoin ? "Pre-join Questions" : "Post-join Questions",
            confirmTitle: "Save",
            canConfirm: working.isComplete
        ) {
            commit(working)
        } content: {
            TextField("Enter a question...", text: $working.title)
                .textFieldStyle(.roundedBorder)

            SheetField(title: "Answers", isRequired: true) {
                VStack(alignment: .leading, spacing: Spacing.base) {
                    ForEach(Array(working.options.enumerated()), id: \.element.id) { index, _ in
                        OnboardingAnswerRow(
                            option: Binding(
                                get: { working.options[index] },
                                set: { working.options[index] = $0 }
                            ),
                            store: store
                        ) {
                            working.options.remove(at: index)
                        }
                    }
                    if working.options.count < OnboardingDraft.maximumAnswers {
                        Button {
                            working.options.append(OnboardingDraft.Option())
                        } label: {
                            Label("Add an Answer", systemImage: "plus")
                                .font(SettingsType.rowLabel)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Palette.accent)
                    }
                }
            }

            VStack(alignment: .leading, spacing: Spacing.base) {
                Toggle(
                    "Allow multiple answers",
                    isOn: Binding(
                        get: { !working.isSingleSelect },
                        set: { working.isSingleSelect = !$0 }
                    )
                )
                // Discord's own rule: a question asked after joining cannot
                // be required.
                Toggle("Required", isOn: $working.isRequired)
                    .disabled(!working.isPreJoin)
                    .help(working.isPreJoin ? "" : "Question must be asked before join to be Required")
            }
            .toggleStyle(.checkbox)
        }
    }
}

/// One answer: an emoji, its words, and the channels and roles it gives.
private struct OnboardingAnswerRow: View {
    @Binding var option: OnboardingDraft.Option
    let store: ServerSettingsStore
    var remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            HStack(spacing: Spacing.base) {
                // Discord's emoji button, which opens the picker — this was a
                // text field with an emoji for a placeholder, which took a
                // click as a cursor and could not be picked from.
                EmojiSlotButton(
                    emoji: $option.emoji,
                    addLabel: "Select emoji",
                    updateLabel: { "Select emoji, \($0.name)" },
                    side: 28
                )

                TextField("Answer", text: $option.title)
                    .textFieldStyle(.plain)
                    .font(SettingsType.rowLabel)

                RowIconButton(symbolName: "xmark", label: "Delete", role: .destructive) {
                    remove()
                }
            }

            HStack(spacing: Spacing.base) {
                grantMenu(
                    "Channels",
                    count: option.channelIDs.count,
                    options: store.textChannels.map { ($0.id.rawValue, "#\($0.name)") },
                    chosen: Set(option.channelIDs.map(\.rawValue))
                ) { raw in
                    let id = ChannelID(rawValue: raw)
                    if option.channelIDs.contains(id) { option.channelIDs.removeAll { $0 == id } }
                    else { option.channelIDs.append(id) }
                }
                grantMenu(
                    "Roles",
                    count: option.roleIDs.count,
                    options: (store.roles.value ?? [])
                        .filter { !$0.isEveryone(in: store.guildID) }
                        .map { ($0.id.rawValue, $0.name) },
                    chosen: Set(option.roleIDs.map(\.rawValue))
                ) { raw in
                    let id = RoleID(rawValue: raw)
                    if option.roleIDs.contains(id) { option.roleIDs.removeAll { $0 == id } }
                    else { option.roleIDs.append(id) }
                }
                Spacer()
            }
        }
        .padding(Spacing.base)
        .background(SettingsSurface.controlTrough, in: .settingsRect(8))
    }

    private func grantMenu(
        _ title: String,
        count: Int,
        options: [(UInt64, String)],
        chosen: Set<UInt64>,
        toggle: @escaping @MainActor (UInt64) -> Void
    ) -> some View {
        Menu {
            ForEach(options, id: \.0) { entry in
                Button {
                    toggle(entry.0)
                } label: {
                    if chosen.contains(entry.0) {
                        Label(entry.1, systemImage: "checkmark")
                    } else {
                        Text(entry.1)
                    }
                }
            }
        } label: {
            Text(count == 0 ? title : "\(title) · \(count)")
                .font(.system(.caption))
                .foregroundStyle(count == 0 ? AnyShapeStyle(Ink.tertiary) : AnyShapeStyle(Palette.accent))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}
