import SwiftUI
import WingcordCore

// MARK: - Editing onboarding
//
// **The route merges per field**, which is what makes this page three
// independent saves rather than one — see `DiscordREST.setOnboardingChannels`.
// The Enable switch does not need to know what the question editor is holding,
// and that is the whole reason it cannot race it.
//
// This page used to be read-only, with a notice saying a save would erase the
// server's questions. That was wrong; HANDOFF §SM.11 has the correction.

struct OnboardingEditor: View {
    let store: ServerSettingsStore
    var onboarding: GuildOnboarding

    @State private var draft: OnboardingDraft?
    @State private var editing: OnboardingDraft.Prompt?

    private var working: OnboardingDraft { draft ?? OnboardingDraft(onboarding) }
    private var isDirty: Bool { draft != nil && draft != OnboardingDraft(onboarding) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            enableCard
            defaultChannels
            questions(
                "Pre-join questions",
                detail: "Asked before somebody joins. These can assign channels and roles.",
                prompts: working.preJoin,
                isPreJoin: true
            )
            questions(
                "Post-join questions",
                detail: "Asked afterwards, on the Channels & Roles page. Good for "
                    + "roles people pick later, like vanity roles.",
                prompts: working.postJoin,
                isPreJoin: false
            )
            saveBar
        }
        .sheet(item: $editing) { prompt in
            OnboardingPromptSheet(
                prompt: prompt,
                store: store
            ) { edited in
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

    private var enableCard: some View {
        SettingsGroup {
            SettingsCard {
                SettingsToggle(
                    title: "Onboarding is enabled",
                    help: "New members are asked these questions before they can "
                        + "see the server.",
                    isOn: Binding(
                        get: { onboarding.isEnabled },
                        // Its own save, and independent of the questions — the
                        // route merges, so this cannot clobber an edit in
                        // progress.
                        set: { isOn in Task { await store.setOnboardingEnabled(isOn) } }
                    )
                )
            }
            if !working.isSavable {
                SettingsFootnote(
                    "A question with no title or no answers will be refused.",
                    symbolName: "exclamationmark.circle"
                )
            }
        }
    }

    private var defaultChannels: some View {
        SettingsGroup("Default channels") {
            SettingsCard {
                ForEach(store.textChannels) { channel in
                    let isOn = onboarding.defaultChannelIDs.contains(channel.id)
                    SettingsToggle(
                        title: "#\(channel.name)",
                        help: channel.isPublic
                            ? nil
                            : "Everyone cannot see this channel, so it will not "
                                + "count toward onboarding's requirement.",
                        isOn: Binding(
                            get: { isOn },
                            set: { wanted in
                                var ids = onboarding.defaultChannelIDs
                                if wanted { ids.append(channel.id) }
                                else { ids.removeAll { $0 == channel.id } }
                                Task { await store.saveOnboardingChannels(ids) }
                            }
                        )
                    )
                    CardDivider()
                }
            }
            SettingsFootnote(
                "Everybody gets these when they join. At least one must be a "
                    + "channel @everyone can both read and send in — \(chattableCount) "
                    + "of the \(onboarding.defaultChannelIDs.count) chosen "
                    + (chattableCount == 1 ? "is." : "are.")
            )
        }
    }

    /// The count onboarding's own constraint is about. Computed from the
    /// resident channel list, which already knows what `@everyone` can see.
    private var chattableCount: Int {
        onboarding.defaultChannelIDs.filter { id in
            store.channels.first { $0.id == id }?.isPublic ?? false
        }.count
    }

    @ViewBuilder
    private func questions(
        _ title: String,
        detail: String,
        prompts: [OnboardingDraft.Prompt],
        isPreJoin: Bool
    ) -> some View {
        SettingsGroup(title) {
            ForEach(prompts) { prompt in
                SettingsCard {
                    ObjectRow(
                        title: prompt.title.isEmpty ? "Untitled question" : prompt.title,
                        subtitle: qualifiers(prompt),
                        badge: prompt.options.count == 1
                            ? "1 answer"
                            : "\(prompt.options.count) answers"
                    ) {
                        Image(systemName: "questionmark.circle")
                            .font(.system(size: 13))
                            .foregroundStyle(Ink.secondary)
                            .frame(width: 28, height: 28)
                    } trailing: {
                        HStack(spacing: 2) {
                            RowIconButton(symbolName: "pencil", label: "Edit question") {
                                editing = prompt
                            }
                            RowIconButton(
                                symbolName: "trash",
                                label: "Remove question",
                                role: .destructive
                            ) {
                                var next = working
                                next.prompts.removeAll { $0.id == prompt.id }
                                draft = next
                            }
                        }
                    }
                }
                .padding(.bottom, Spacing.base)
            }

            SettingsCard {
                SettingsActionRow("Add a question", actionTitle: "Add") {
                    editing = OnboardingDraft.Prompt(isPreJoin: isPreJoin)
                }
            }
            SettingsFootnote(detail)
        }
    }

    private func qualifiers(_ prompt: OnboardingDraft.Prompt) -> String {
        var parts = [prompt.isSingleSelect ? "One answer" : "Multiple answers"]
        // **Required is meaningless after somebody is already in**, which is why
        // Discord's own editor omits it from post-join questions.
        if prompt.isPreJoin, prompt.isRequired { parts.append("required") }
        if prompt.options.contains(where: \.grantsNothing) {
            parts.append("an answer grants nothing")
        }
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
                Button("Save questions") {
                    Task {
                        await store.saveOnboardingPrompts(working.prompts)
                        draft = nil
                    }
                }
                .buttonStyle(.glassProminent)
                .disabled(!working.isSavable)
            }
            .padding(.top, Spacing.margin)
        }
    }
}

// MARK: - One question

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
            title: working.isPreJoin ? "Pre-join question" : "Post-join question",
            confirmTitle: "Done",
            canConfirm: working.isComplete
        ) {
            commit(working)
        } content: {
            SheetField(title: "Question", isRequired: true) {
                TextField("What do you want to do in this community?", text: $working.title)
                    .textFieldStyle(.roundedBorder)
            }

            SheetField(
                title: "Answers — \(working.options.count) of \(OnboardingDraft.maximumAnswers)",
                isRequired: true
            ) {
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
                            Label("Add an answer", systemImage: "plus")
                                .font(SettingsType.rowLabel)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Palette.accent)
                    }
                }
            }

            SheetField(title: "Behaviour") {
                VStack(alignment: .leading, spacing: Spacing.base) {
                    Toggle(
                        "Allow multiple answers",
                        isOn: Binding(
                            get: { !working.isSingleSelect },
                            set: { working.isSingleSelect = !$0 }
                        )
                    )
                    // Omitted on a post-join question, exactly as Discord's own
                    // editor does — requiring an answer from somebody who is
                    // already in the server means nothing.
                    if working.isPreJoin {
                        Toggle("Required", isOn: $working.isRequired)
                    }
                }
                .toggleStyle(.checkbox)
            }
        }
    }
}

/// One answer: an emoji, a label, and what choosing it grants.
private struct OnboardingAnswerRow: View {
    @Binding var option: OnboardingDraft.Option
    let store: ServerSettingsStore
    var remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            HStack(spacing: Spacing.base) {
                TextField(
                    "🙂",
                    text: Binding(
                        get: { option.emojiName ?? "" },
                        set: { option.emojiName = $0.isEmpty ? nil : $0 }
                    )
                )
                .textFieldStyle(.plain)
                .frame(width: 28)
                .multilineTextAlignment(.center)

                TextField("Answer", text: $option.title)
                    .textFieldStyle(.plain)
                    .font(SettingsType.rowLabel)

                RowIconButton(symbolName: "xmark", label: "Remove answer", role: .destructive) {
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
                // Discord allows an answer that grants nothing; it is still
                // almost always a mistake, so the row says so rather than
                // refusing it.
                if option.grantsNothing {
                    Text("grants nothing")
                        .font(.system(.caption))
                        .foregroundStyle(.orange)
                }
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
