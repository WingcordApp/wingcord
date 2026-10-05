import SwiftUI
import WingcordCore

// MARK: - Access
//
// Discord's Access page (`Aq`): "How can people join your server?" over three
// tiles, Age-Restricted Server, then what the chosen way needs — the Server
// Rules for Invite Only, the Join Application and Apply from Profile for Apply
// to Join, the requirements for Discoverable. Every word is Discord's.
//
// **One form behind two modes.** `PATCH /guilds/{id}/member-verification`
// carries the rules (`TERMS`) and an application's questions alike: Invite
// Only sends the rules alone, enabled when they are required; Apply to Join
// sends them with the questions, enabled.

struct AccessPane: View {
    let store: ServerSettingsStore
    let model: AppModel

    var body: some View {
        LoadableContent(store.settings) { settings in
            let mode = GuildAccessMode(features: settings.features)
            VStack(alignment: .leading, spacing: 0) {
                joinMode(settings, mode: mode)
                ageGate(settings, mode: mode)
                LoadableContent(store.joinForm) { form in
                    switch mode {
                    case .inviteOnly:
                        ServerRulesEditor(store: store, form: form)
                    case .applyToJoin:
                        JoinApplicationEditor(store: store, model: model, form: form)
                    case .discoverable:
                        EmptyView()
                    }
                }
            }
        }
    }

    // MARK: How people join

    private func joinMode(_ settings: GuildSettings, mode: GuildAccessMode) -> some View {
        SettingsGroup("How can people join your server?") {
            HStack(spacing: Spacing.base) {
                ForEach(GuildAccessMode.allCases) { candidate in
                    AccessTile(
                        mode: candidate,
                        isSelected: candidate == mode,
                        isEnabled: isSelectable(candidate, settings: settings)
                    ) {
                        choose(candidate, settings: settings)
                    }
                }
            }
            if !settings.isCommunity {
                SettingsFootnote("Enable Community to access Server Discovery")
            } else if mode != .discoverable, !(store.discoveryRequirements.value?.isSufficient ?? true) {
                DiscoveryRequirementsCard(store: store)
            }
        }
    }

    private func ageGate(_ settings: GuildSettings, mode: GuildAccessMode) -> some View {
        SettingsGroup {
            SettingsCard {
                DescribedRow(
                    "Age-Restricted Server",
                    detail: Text("Users will need to confirm they are over the legal age to view the content in this server [Learn more.](https://support.discord.com/hc/en-us/articles/1500005292701)")
                ) {
                    Toggle("Age-Restricted Server", isOn: Binding(
                        get: { settings.contentLevel.isAgeRestricted },
                        set: { isOn in
                            Task { await store.saveContentLevel(isOn ? .ageRestricted : .default) }
                        }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .tint(SettingsSurface.switchOn)
                    // Discord's: a discoverable server cannot be age-restricted.
                    .disabled(mode == .discoverable)
                }
            }
        }
    }

    /// Discoverable is refused outright until the server meets its
    /// requirements; Discord says so after the press, this before it.
    private func isSelectable(_ mode: GuildAccessMode, settings: GuildSettings) -> Bool {
        switch mode {
        case .inviteOnly, .applyToJoin: true
        case .discoverable: settings.isCommunity && (store.discoveryRequirements.value?.isSufficient ?? false)
        }
    }

    /// Discord's save for each way in (`AQ`): Invite Only keeps the rules and
    /// drops the questions; Apply to Join keeps both and turns the form on.
    private func choose(_ mode: GuildAccessMode, settings: GuildSettings) {
        var form = store.joinForm.value ?? JoinApplicationForm(guildID: store.guildID)
        switch mode {
        case .inviteOnly:
            form.fields.removeAll { !$0.kind.isTerms }
            form.isEnabled = form.fields.contains { $0.kind.isTerms }
            Task { await store.saveJoinForm(form) }
        case .applyToJoin:
            if !form.fields.contains(where: { !$0.kind.isTerms }) {
                form.fields.append(JoinApplicationForm.Field(label: "Do you play any of the same games as us?"))
            }
            form.isEnabled = true
            Task { await store.saveJoinForm(form) }
        case .discoverable:
            // Joining discovery is an application with a category and
            // keywords, not a flag a client may set; the tile stays disabled.
            break
        }
    }
}

private struct AccessTile: View {
    var mode: GuildAccessMode
    var isSelected: Bool
    var isEnabled: Bool
    var choose: () -> Void

    var body: some View {
        Button(action: choose) {
            VStack(spacing: Spacing.base) {
                Image(symbol: mode.symbolName)
                    .font(.system(size: 18))
                    .foregroundStyle(isEnabled ? Ink.primary : Ink.tertiary)
                Text(mode.title)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(isEnabled ? Ink.primary : Ink.tertiary)
                Text(mode.detail)
                    .font(.system(.caption))
                    .foregroundStyle(Ink.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.margin)
            .padding(.horizontal, Spacing.snug)
            .background(
                isSelected ? SettingsSurface.controlSelected : SettingsSurface.card,
                in: .settingsRect(10)
            )
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Palette.accent, lineWidth: 1.5)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

// MARK: - Server Rules

/// Invite Only's Server Rules (`Ab`): whether members must agree, and the
/// rules — written, removed, or taken from Discord's examples.
private struct ServerRulesEditor: View {
    let store: ServerSettingsStore
    var form: JoinApplicationForm

    @State private var rules: [EditableRule] = []
    @State private var requiresRules = false
    @State private var adopted = false

    /// Discord's examples (`e729aaf9`): the pill's words, and the rule it adds.
    private static let examples: [(title: String, rule: String)] = [
        ("Be civil and respectful", "Treat everyone with respect. Absolutely no harassment, witch hunting, sexism, racism, or hate speech will be tolerated."),
        ("No spam or self-promotion", "No spam or self-promotion (server invites, advertisements, etc) without permission from a staff member. This includes DMing fellow members."),
        ("No age-restricted or obscene content", "No age-restricted or obscene content. This includes text, images, or links featuring nudity, sex, hard violence, or other graphically disturbing content."),
        ("Help keep things safe", "If you see something against the rules or something that makes you feel unsafe, let staff know. We want this server to be a welcoming space!"),
    ]

    struct EditableRule: Identifiable, Hashable {
        var id = UUID()
        var text: String
    }

    private var savedRules: [String] {
        guard case .terms(let values)? = form.fields.first(where: { $0.kind.isTerms })?.kind else { return [] }
        return values
    }

    private var isDirty: Bool {
        requiresRules != form.isEnabled || rules.map(\.text) != savedRules
    }

    var body: some View {
        SettingsGroup {
            SettingsCard {
                DescribedRow(
                    "Server Rules",
                    detail: Text("Members must agree to rules before they can chat or interact in the server.")
                ) {
                    Toggle("Server Rules", isOn: $requiresRules)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                        .tint(SettingsSurface.switchOn)
                }
                if requiresRules {
                    CardDivider()
                    VStack(alignment: .leading, spacing: Spacing.base) {
                        Text("RULES")
                            .font(.system(.caption2, weight: .bold))
                            .foregroundStyle(Ink.tertiary)
                        ForEach($rules) { $rule in
                            HStack(spacing: Spacing.base) {
                                TextField("Enter a rule", text: $rule.text, axis: .vertical)
                                    .textFieldStyle(.plain)
                                    .font(SettingsType.rowLabel)
                                RowIconButton(symbolName: "xmark", label: "Clear", role: .destructive) {
                                    rules.removeAll { $0.id == rule.id }
                                }
                            }
                            .padding(Spacing.base)
                            .background(SettingsSurface.controlTrough, in: .settingsRect(8))
                        }
                        Button {
                            rules.append(EditableRule(text: ""))
                        } label: {
                            Label("Add a rule", systemImage: "plus")
                                .font(SettingsType.rowLabel)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Palette.accent)
                        examples
                    }
                    .padding(SettingsMetrics.cardContentInset)
                }
            }
            if isDirty {
                UnsavedChangesBar(
                    canSave: !requiresRules || rules.contains { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty },
                    reset: adopt,
                    save: save
                )
                .padding(.top, Spacing.margin)
            }
        }
        .onAppear { if !adopted { adopt() } }
        .onChange(of: form) { adopt() }
    }

    @ViewBuilder
    private var examples: some View {
        let unused = Self.examples.filter { example in !rules.contains { $0.text == example.rule } }
        if !unused.isEmpty {
            Text("Example rules")
                .font(.system(.caption2, weight: .bold))
                .foregroundStyle(Ink.tertiary)
                .padding(.top, Spacing.base)
            FlowLayout(spacing: Spacing.tight) {
                ForEach(unused, id: \.title) { example in
                    Button {
                        rules.append(EditableRule(text: example.rule))
                    } label: {
                        Text(example.title)
                            .font(.system(.caption))
                            .padding(.horizontal, Spacing.snug)
                            .padding(.vertical, 5)
                            .background(SettingsSurface.controlTrough, in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Ink.primary)
                }
            }
        }
    }

    private func adopt() {
        adopted = true
        requiresRules = form.isEnabled
        rules = savedRules.map { EditableRule(text: $0) }
    }

    /// Discord's `N`: the rules as one `TERMS` field when they are required,
    /// enabled with them; nothing and disabled when they are not.
    private func save() {
        var next = form
        let written = rules.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        next.fields.removeAll { $0.kind.isTerms }
        if requiresRules, !written.isEmpty {
            next.fields.insert(
                JoinApplicationForm.Field(kind: .terms(written), label: "Read and agree to the server rules"),
                at: 0
            )
        }
        next.isEnabled = requiresRules && !written.isEmpty
        Task { await store.saveJoinForm(next) }
    }
}

// MARK: - Join Application

/// Apply to Join's Join Application (`Ah`): the questions, Discord's examples,
/// and Apply from Profile with its preview — the server's card ending in an
/// Apply to Join button.
private struct JoinApplicationEditor: View {
    let store: ServerSettingsStore
    let model: AppModel
    var form: JoinApplicationForm

    @State private var draft: JoinApplicationForm?

    private var working: JoinApplicationForm { draft ?? form }
    private var questions: [JoinApplicationForm.Field] { working.fields.filter { !$0.kind.isTerms } }
    private var isDirty: Bool { draft != nil && draft?.fields != form.fields }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup("Join Application") {
                Text("Add questions to your application. People don\u{2019}t join your server until you approve their application. You\u{2019}ll have the option to DM applicants before approving or denying them.")
                    .font(SettingsType.rowSubtitle)
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, Spacing.snug)
                Text("Questions (\(questions.count)/\(JoinApplicationForm.maximumQuestions))")
                    .font(.system(.caption2, weight: .bold))
                    .foregroundStyle(Ink.tertiary)
                    .padding(.bottom, Spacing.tight)
                SettingsCard {
                    ForEach(Array(questions.enumerated()), id: \.element.id) { index, field in
                        if index > 0 { CardDivider() }
                        questionRow(field)
                    }
                }
                if questions.count < JoinApplicationForm.maximumQuestions {
                    addQuestion
                        .padding(.top, Spacing.snug)
                    examples
                }
                if isDirty {
                    UnsavedChangesBar(
                        canSave: !questions.isEmpty && questions.allSatisfy(isComplete),
                        reset: { draft = nil },
                        save: {
                            let saved = working
                            Task {
                                await store.saveJoinForm(saved)
                                draft = nil
                            }
                        }
                    )
                    .padding(.top, Spacing.margin)
                }
            }
            ApplyFromProfileSection(store: store, model: model)
        }
    }

    private func questionRow(_ field: JoinApplicationForm.Field) -> some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            questionLine(field)
            if case .multipleChoice(let choices) = field.kind {
                choicesEditor(field.id, choices: choices)
            }
        }
        .padding(.horizontal, SettingsMetrics.cardContentInset)
        .padding(.vertical, Spacing.snug)
    }

    /// A multiple-choice question's options — "Add an option", each with
    /// Clear; Discord asks for at least two.
    private func choicesEditor(_ id: UUID, choices: [String]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            ForEach(Array(choices.enumerated()), id: \.offset) { index, choice in
                HStack(spacing: Spacing.base) {
                    Image(systemName: "circle")
                        .font(.system(size: 10))
                        .foregroundStyle(Ink.tertiary)
                    TextField("Add an option", text: Binding(
                        get: { choice },
                        set: { text in setChoices(id) { $0[index] = String(text.prefix(150)) } }
                    ))
                    .textFieldStyle(.plain)
                    .font(SettingsType.rowSubtitle)
                    RowIconButton(symbolName: "xmark", label: "Clear", role: .destructive) {
                        setChoices(id) { $0.remove(at: index) }
                    }
                }
            }
            Button {
                setChoices(id) { $0.append("") }
            } label: {
                Label("Add an option", systemImage: "plus")
                    .font(.system(.caption))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.accent)
            if choices.filter({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }).count < 2 {
                Text("You need at least two or more choices.")
                    .font(.system(.caption))
                    .foregroundStyle(Palette.destructive)
            }
        }
        .padding(.leading, Spacing.margin)
    }

    private func setChoices(_ id: UUID, _ change: (inout [String]) -> Void) {
        edit(id) { field in
            guard case .multipleChoice(var choices) = field.kind else { return }
            change(&choices)
            field.kind = .multipleChoice(choices)
        }
    }

    private func questionLine(_ field: JoinApplicationForm.Field) -> some View {
        HStack(spacing: Spacing.base) {
            TextField(
                "Enter a question...",
                text: Binding(
                    get: { working.fields.first { $0.id == field.id }?.label ?? "" },
                    set: { text in edit(field.id) { $0.label = String(text.prefix(300)) } }
                )
            )
            .textFieldStyle(.plain)
            .font(SettingsType.rowLabel)
            .disabled(!field.kind.isEditable)
            Text(field.kind.title)
                .font(.system(.caption))
                .foregroundStyle(Ink.tertiary)
            Toggle("Required", isOn: Binding(
                get: { working.fields.first { $0.id == field.id }?.isRequired ?? true },
                set: { isOn in edit(field.id) { $0.isRequired = isOn } }
            ))
            .toggleStyle(.checkbox)
            .font(.system(.caption))
            RowIconButton(symbolName: "trash", label: "Delete", role: .destructive) {
                var next = working
                next.fields.removeAll { $0.id == field.id }
                draft = next
            }
            .disabled(questions.count <= 1)
        }
    }

    /// The kinds of question Discord's menu offers.
    private var addQuestion: some View {
        Menu {
            ForEach(JoinApplicationForm.Field.Kind.selectable, id: \.self) { kind in
                Button(kind.title) {
                    var next = working
                    next.fields.append(JoinApplicationForm.Field(kind: kind, label: ""))
                    draft = next
                }
            }
        } label: {
            Label("Add a Question", systemImage: "plus")
                .font(SettingsType.rowLabel)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    /// Discord's three example questions (`Ad`).
    private var examples: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            Text("Example questions")
                .font(.system(.caption2, weight: .bold))
                .foregroundStyle(Ink.tertiary)
            FlowLayout(spacing: Spacing.tight) {
                ForEach(JoinApplicationForm.exampleQuestions, id: \.self) { example in
                    Button {
                        var next = working
                        next.fields.append(JoinApplicationForm.Field(label: example))
                        draft = next
                    } label: {
                        Text(example)
                            .font(.system(.caption))
                            .padding(.horizontal, Spacing.snug)
                            .padding(.vertical, 5)
                            .background(SettingsSurface.controlTrough, in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Ink.primary)
                }
            }
        }
        .padding(.top, Spacing.snug)
    }

    /// A question Discord would take: words in it, and two choices at least
    /// where it is multiple choice ("You must enter a question.", "You need at
    /// least two or more choices.").
    private func isComplete(_ field: JoinApplicationForm.Field) -> Bool {
        guard !field.label.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if case .multipleChoice(let choices) = field.kind {
            return choices.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count >= 2
        }
        return true
    }

    private func edit(_ id: UUID, _ change: (inout JoinApplicationForm.Field) -> Void) {
        var next = working
        guard let index = next.fields.firstIndex(where: { $0.id == id }) else { return }
        change(&next.fields[index])
        draft = next
    }
}

/// "Apply from Profile" (`Ah`): profile visibility 3, public with recruitment,
/// beside the card a stranger sees — Discord's preview, its button Apply to
/// Join. A private profile cannot offer it, and says where to change that.
private struct ApplyFromProfileSection: View {
    let store: ServerSettingsStore
    let model: AppModel

    var body: some View {
        LoadableContent(store.profile) { profile in
            let isPrivate = profile.isPrivateProfile
            SettingsGroup {
                SettingsCard {
                    HStack(alignment: .top, spacing: Spacing.margin) {
                        VStack(alignment: .leading, spacing: Spacing.tight) {
                            Toggle(isOn: Binding(
                                get: { profile.visibility == 3 },
                                set: { isOn in
                                    var next = profile
                                    next.visibility = isOn ? 3 : 1
                                    Task { await store.saveProfile(next) }
                                }
                            )) {
                                Text("Apply from Profile")
                                    .font(SettingsType.rowTitle)
                            }
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .tint(SettingsSurface.switchOn)
                            .disabled(isPrivate)
                            Text("Allow people who see your server profile to apply.")
                                .font(SettingsType.rowSubtitle)
                                .foregroundStyle(Ink.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if isPrivate {
                                Text("You can\u{2019}t enable Apply from Profile if your server has \u{201C}Private Profile\u{201D} enabled. You can change this setting in the Profile tab.")
                                    .font(.system(.caption))
                                    .foregroundStyle(Ink.tertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        ApplyPreviewCard(model: model, guildID: store.guildID)
                    }
                    .padding(SettingsMetrics.cardContentInset)
                }
            }
        }
    }
}

/// The server's card as somebody outside it sees it, ending in Apply to Join —
/// a picture of the control, not the control.
private struct ApplyPreviewCard: View {
    let model: AppModel
    var guildID: GuildID

    var body: some View {
        var card = model.guildProfilePresentation(of: guildID, tag: nil)
        card.isJoined = false
        card.isLoading = false
        card.entry = .apply
        return GuildProfileCard(profile: card, openGuild: { _ in }, enterGuild: { _ in })
            .background(Palette.surfaceRaised)
            .clipShape(.rect(cornerRadius: Radius.card, style: .continuous))
            .scaleEffect(0.8, anchor: .topTrailing)
            .frame(width: 256, height: 300, alignment: .topTrailing)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Why discovery is refused.
private struct DiscoveryRequirementsCard: View {
    let store: ServerSettingsStore

    var body: some View {
        LoadableContent(store.discoveryRequirements) { requirements in
            SettingsCard {
                ForEach(Array(requirements.requirements.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { CardDivider() }
                    HStack(alignment: .top, spacing: Spacing.snug) {
                        Image(symbol: symbol(item.outcome))
                            .font(.system(size: 13))
                            .foregroundStyle(tint(item.outcome))
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(SettingsType.rowTitle)
                                .foregroundStyle(Ink.primary)
                            Text(item.detail)
                                .font(SettingsType.rowSubtitle)
                                .foregroundStyle(Ink.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, SettingsMetrics.cardContentInset)
                    .padding(.vertical, Spacing.snug)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func symbol(_ outcome: DiscoveryRequirements.Requirement.Outcome) -> String {
        switch outcome {
        case .met: "checkmark.circle.fill"
        case .unmet: "xmark.circle.fill"
        case .pending: "exclamationmark.circle.fill"
        }
    }

    /// **Pending is not a failure.** Discord cannot measure activity below a
    /// couple of hundred members, which is the ordinary case — drawing it as a
    /// cross would tell most servers they had failed something nobody has
    /// measured.
    private func tint(_ outcome: DiscoveryRequirements.Requirement.Outcome) -> Color {
        switch outcome {
        case .met: Palette.affirmative
        case .unmet: Palette.destructive
        case .pending: .orange
        }
    }
}

