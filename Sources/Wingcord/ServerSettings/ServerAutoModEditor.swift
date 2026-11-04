import SwiftUI
import WingcordCore

// MARK: - Building an AutoMod rule
//
// The reason this took a capture rather than a decision: **four things are
// decided by the trigger type**, and offering a control the trigger refuses is
// the inert control `INVARIANTS.md` §5.5 is about.
//
//   - `event_type` is derived, never asked for — 2 for a profile rule, 1 for
//     everything else.
//   - Actions are gated: timeout only on keyword and mention-spam, quarantine
//     only on user-profile, and a server-rules rule takes *only* an alert.
//   - Channel exemptions mean nothing on a profile rule, which fires on a member.
//   - Each kind has a per-guild limit, and keyword is the only one above 1.
//
// All four live on `AutoModRule.Trigger` so this sheet reads them rather than
// re-deriving them.

struct AutoModSheet: View {
    var existing: AutoModRule?
    let store: ServerSettingsStore
    var commit: (AutoModDraft, UInt64?) -> Void

    @State private var draft: AutoModDraft
    /// The last refusal from `/validate`. Shown against the regex field, since
    /// that is the only thing the route actually checks.
    @State private var failure: String?

    init(
        existing: AutoModRule?,
        store: ServerSettingsStore,
        commit: @escaping (AutoModDraft, UInt64?) -> Void
    ) {
        self.existing = existing
        self.store = store
        self.commit = commit
        _draft = State(initialValue: existing.map(AutoModDraft.init) ?? AutoModDraft())
    }

    var body: some View {
        SheetFrame(
            title: existing == nil ? Self.discordName(draft.trigger) : "Edit Rule",
            confirmTitle: existing == nil ? "Create" : "Save",
            canConfirm: draft.isSavable
        ) {
            commit(draft, existing?.id)
        } content: {
            SheetField(title: "Rule Name", isRequired: true) {
                TextField("Enter a rule name", text: $draft.name)
                    .modalField()
            }

            // The trigger is fixed once a rule exists: changing it would rewrite
            // the metadata, and Discord treats the two as one thing.
            if existing == nil {
                SheetField(title: "Content", isRequired: true) {
                    VStack(alignment: .leading, spacing: Spacing.base) {
                        ForEach(Array(AutoModRule.Trigger.creatable.enumerated()), id: \.offset) { _, candidate in
                            TriggerChoice(
                                trigger: candidate,
                                isSelected: draft.trigger.wireType == candidate.wireType,
                                remaining: remaining(candidate)
                            ) {
                                draft.trigger = candidate
                                // The action list is trigger-dependent, so a
                                // change has to drop whatever is no longer
                                // permitted rather than send it and be refused.
                                let allowed = Set(candidate.permittedActions.map(\.wireType))
                                draft.actions = draft.actions.filter { allowed.contains($0.wireType) }
                                if draft.actions.isEmpty {
                                    draft.actions = [candidate.permittedActions[0]]
                                }
                            }
                        }
                    }
                }
            } else {
                SheetField(title: "Content") {
                    Text(Self.discordName(draft.trigger))
                        .font(SettingsType.rowLabel)
                        .foregroundStyle(Ink.secondary)
                }
            }

            triggerFields

            SheetField(title: "Choose a response", isRequired: true) {
                VStack(alignment: .leading, spacing: Spacing.base) {
                    ForEach(draft.trigger.permittedActions) { candidate in
                        ActionRow(
                            candidate: candidate,
                            draft: $draft,
                            channels: store.textChannels
                        )
                    }
                }
            }

            SheetField(
                title: draft.trigger.allowsChannelExemptions
                    ? "Allow certain roles or channels (optional)"
                    : "Allow certain roles (optional)",
                detail: "Pssst \u{2014} members with Admin and Manage Server permissions are always excluded from filter rules."
            ) {
                exemptMenu(
                    options: (store.roles.value ?? [])
                        .filter { !$0.isEveryone(in: store.guildID) }
                        .map { ($0.id.rawValue, $0.name) },
                    chosen: Set(draft.exemptRoleIDs.map(\.rawValue))
                ) { raw in
                    let id = RoleID(rawValue: raw)
                    if draft.exemptRoleIDs.contains(id) { draft.exemptRoleIDs.removeAll { $0 == id } }
                    else { draft.exemptRoleIDs.append(id) }
                }
            }

            // Meaningless on a profile rule, which fires on a member joining
            // rather than in a channel — so it is absent rather than dimmed.
            if draft.trigger.allowsChannelExemptions {
                SheetField(title: "Channels") {
                    exemptMenu(
                        options: store.textChannels.map { ($0.id.rawValue, "#\($0.name)") },
                        chosen: Set(draft.exemptChannelIDs.map(\.rawValue))
                    ) { raw in
                        let id = ChannelID(rawValue: raw)
                        if draft.exemptChannelIDs.contains(id) {
                            draft.exemptChannelIDs.removeAll { $0 == id }
                        } else {
                            draft.exemptChannelIDs.append(id)
                        }
                    }
                }
            }
        }
    }

    /// Discord's name for each kind of rule, from its AutoMod page.
    static func discordName(_ trigger: AutoModRule.Trigger) -> String {
        switch trigger {
        case .keyword: "Block Custom Words"
        case .keywordPreset: "Block Commonly Flagged Words"
        case .mentionSpam: "Block Mention Spam"
        case .userProfile: "Block Words in Member Profile Names"
        case .spam: "Block messages with spam-like content from being posted."
        case .guildPolicy, .unrecognised: "AutoMod"
        }
    }

    @ViewBuilder
    private var triggerFields: some View {
        switch draft.trigger {
        case .keyword(let filter, let regexes, let allowList),
             .userProfile(let filter, let regexes, let allowList):
            SheetField(
                title: "Choose your words",
                detail: "Use the * character at the beginning or end of your keyword for partial matches within a word."
            ) {
                listField(filter, limit: AutoModRule.Trigger.Limits.keywordCount) { next in
                    setKeywordMetadata(filter: next, regexes: regexes, allowList: allowList)
                }
            }
            // Rust regex, not ICU: a pattern that compiles on this side may
            // still be refused, which is what /validate is for.
            SheetField(title: "Use regex patterns for advanced matching (optional)") {
                listField(regexes, limit: AutoModRule.Trigger.Limits.regexCount) { next in
                    setKeywordMetadata(filter: filter, regexes: next, allowList: allowList)
                }
            }
            SheetField(title: "Allow words and phrases (optional)") {
                listField(allowList, limit: AutoModRule.Trigger.Limits.allowListCount) { next in
                    setKeywordMetadata(filter: filter, regexes: regexes, allowList: next)
                }
            }

        case .keywordPreset(let presets, let allowList):
            SheetField(title: "Choose your words", isRequired: true) {
                VStack(alignment: .leading, spacing: Spacing.base) {
                    ForEach(AutoModRule.KeywordPreset.selectable, id: \.rawValue) { preset in
                        Toggle(isOn: Binding(
                            get: { presets.contains(preset) },
                            set: { wanted in
                                var next = presets
                                if wanted { next.append(preset) }
                                else { next.removeAll { $0 == preset } }
                                draft.trigger = .keywordPreset(presets: next, allowList: allowList)
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(preset.title)
                                Text(preset.detail)
                                    .font(.system(.caption))
                                    .foregroundStyle(Ink.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
            SheetField(title: "Allow words and phrases (optional)") {
                listField(allowList, limit: 1000) { next in
                    draft.trigger = .keywordPreset(presets: presets, allowList: next)
                }
            }

        case .mentionSpam(let limit, let raid):
            SheetField(
                title: "Unique mentions (role + user) per message",
                detail: "Limit the number of unique mentions in each message."
            ) {
                Picker("", selection: Binding(
                    get: { limit },
                    set: { draft.trigger = .mentionSpam(limit: $0, raidProtection: raid) }
                )) {
                    ForEach([5, 10, 15, 20, 25, 30, 40, 50], id: \.self) { Text("\($0)").tag($0) }
                }
                .labelsHidden()
            }
            SheetField(title: "Enable mention raid detection", detail: "Allow automatic detection of mention raids in the server.") {
                Toggle("Enable mention raid detection", isOn: Binding(
                    get: { raid },
                    set: { draft.trigger = .mentionSpam(limit: limit, raidProtection: $0) }
                ))
                .toggleStyle(.checkbox)
            }

        case .spam, .guildPolicy, .unrecognised:
            EmptyView()
        }
    }

    private func setKeywordMetadata(filter: [String], regexes: [String], allowList: [String]) {
        if case .userProfile = draft.trigger {
            draft.trigger = .userProfile(filter: filter, regexes: regexes, allowList: allowList)
        } else {
            draft.trigger = .keyword(filter: filter, regexes: regexes, allowList: allowList)
        }
    }

    /// A newline-separated list, which is how Discord's own fields take them.
    private func listField(
        _ values: [String],
        limit: Int,
        set: @escaping @MainActor ([String]) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            TextEditor(text: Binding(
                get: { values.joined(separator: "\n") },
                set: { text in
                    set(
                        text.split(separator: "\n", omittingEmptySubsequences: true)
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                    )
                }
            ))
            .scrollContentBackground(.hidden)
            .font(SettingsType.rowLabel)
            .frame(minHeight: 56)
            .padding(Spacing.base)
            .background(SettingsSurface.controlTrough, in: .settingsRect(8))

            Text("\(values.count) / \(limit)")
                .font(.system(.caption).monospacedDigit())
                .foregroundStyle(values.count > limit ? AnyShapeStyle(Palette.destructive) : AnyShapeStyle(Ink.tertiary))
        }
    }

    private func exemptMenu(
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
            Text(chosen.isEmpty ? "None" : "\(chosen.count) selected")
                .font(SettingsType.rowLabel)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    /// How many more of this kind the guild may have.
    private func remaining(_ trigger: AutoModRule.Trigger) -> Int {
        let used = (store.autoModRules.value ?? [])
            .filter { $0.trigger.wireType == trigger.wireType }
            .count
        return max(0, trigger.perGuildLimit - used)
    }
}

private struct TriggerChoice: View {
    var trigger: AutoModRule.Trigger
    var isSelected: Bool
    var remaining: Int
    var choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack(alignment: .top, spacing: Spacing.snug) {
                Image(symbol: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(Ink.tertiary))
                VStack(alignment: .leading, spacing: 1) {
                    Text(AutoModSheet.discordName(trigger))
                        .font(.system(.subheadline, weight: .medium))
                        .foregroundStyle(remaining > 0 ? AnyShapeStyle(Ink.primary) : AnyShapeStyle(Ink.tertiary))
                    // A kind at its limit is dimmed rather than explained in a
                    // sentence Discord never wrote.
                    Text(SafetyPane.triggerLine(trigger))
                    .font(.system(.caption))
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // A kind the guild is already at its limit for cannot be created, and
        // Discord refuses it — so it is dimmed with the reason rather than
        // offered and 400'd.
        .disabled(remaining == 0)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

/// One action, with the field it needs.
private struct ActionRow: View {
    var candidate: AutoModDraft.Action
    @Binding var draft: AutoModDraft
    var channels: [ServerSettingsStore.ChannelSummary]

    private var chosen: AutoModDraft.Action? {
        draft.actions.first { $0.wireType == candidate.wireType }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            Toggle(isOn: Binding(
                get: { chosen != nil },
                set: { wanted in
                    if wanted { draft.actions.append(candidate) }
                    else { draft.actions.removeAll { $0.wireType == candidate.wireType } }
                }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(candidate.title)
                    Text(candidate.detail)
                        .font(.system(.caption))
                        .foregroundStyle(Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)

            if let chosen { detail(chosen) }
        }
    }

    @ViewBuilder
    private func detail(_ action: AutoModDraft.Action) -> some View {
        switch action {
        case .alert(let channelID):
            Picker("Select channel", selection: Binding(
                get: { channelID },
                set: { replace(.alert(channelID: $0)) }
            )) {
                Text("Select channel").tag(ChannelID?.none)
                ForEach(channels) { Text("#\($0.name)").tag(ChannelID?.some($0.id)) }
            }
            .padding(.leading, Spacing.group)

        case .timeout(let seconds):
            Picker("For", selection: Binding(
                get: { seconds },
                set: { replace(.timeout(seconds: $0)) }
            )) {
                ForEach(AutoModDraft.Action.timeoutChoices, id: \.self) { value in
                    Text(AutoModDraft.Action.timeoutTitle(value)).tag(value)
                }
            }
            .padding(.leading, Spacing.group)

        case .blockMessage(let message):
            TextField("Enter your custom message", text: Binding(
                get: { message ?? "" },
                set: { replace(.blockMessage(customMessage: $0.isEmpty ? nil : $0)) }
            ))
            .modalField()
            .padding(.leading, Spacing.group)

        case .quarantine:
            EmptyView()
        }
    }

    private func replace(_ action: AutoModDraft.Action) {
        guard let index = draft.actions.firstIndex(where: { $0.wireType == action.wireType })
        else { return }
        draft.actions[index] = action
    }
}
