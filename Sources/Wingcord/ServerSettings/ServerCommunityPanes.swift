import AppKit
import SwiftUI
import WingcordCore

// MARK: - Community Overview
//
// **Six fields, and all six go back on every save** — see the nine captured
// PATCHes, which sent the identical set each time and differed only in the one
// value that had changed. `saveCommunity` below is where that is enforced, and
// it is why every control on this page routes through one function.

struct CommunityPane: View {
    let store: ServerSettingsStore

    var body: some View {
        LoadableContent(store.settings) { settings in
            VStack(alignment: .leading, spacing: 0) {
                if settings.isCommunity {
                    channels(settings)
                    language(settings)
                    description(settings)
                } else {
                    notCommunity
                }
            }
        }
    }

    /// What this client will not do.
    ///
    /// **Turning community on is not offered.** It is a `features` write that
    /// also demands a verification level, an explicit-content filter, a rules
    /// channel and an updates channel all set in one request — and getting any
    /// of them wrong answers a 400 that names none of them. A wizard that
    /// half-works here would leave a server in a state its owner cannot see.
    /// §5.5: better to say so than to offer it.
    private var notCommunity: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Text("This server is not a Community server.")
                    .font(SettingsType.rowTitle)
                    .foregroundStyle(Ink.primary)
                Text(
                    "Community brings a rules channel, onboarding, a Server Guide "
                        + "and Discord's safety notices. Wingcord does not turn it "
                        + "on — the request sets six things at once and refuses "
                        + "without naming which one it disliked, so it belongs in "
                        + "Discord's own client. Everything it unlocks is editable "
                        + "here once it is on."
                )
                .font(SettingsType.rowSubtitle)
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(SettingsMetrics.cardContentInset)
        }
    }

    private func channels(_ settings: GuildSettings) -> some View {
        SettingsGroup("Channels Discord uses") {
            SettingsCard {
                picker(
                    "Rules or guidelines",
                    help: "Where your rules are written. New members are pointed at it.",
                    selection: settings.rulesChannelID
                ) { saveCommunity(settings, rules: .some($0)) }
                CardDivider()
                picker(
                    "Community updates",
                    help: "Where Discord posts notices for admins and moderators. "
                        + "Worth making this one role-restricted.",
                    selection: settings.publicUpdatesChannelID
                ) { saveCommunity(settings, updates: .some($0)) }
                CardDivider()
                picker(
                    "Safety notices",
                    help: "Where Discord posts safety alerts about this server.",
                    selection: settings.safetyAlertsChannelID
                ) { saveCommunity(settings, safety: .some($0)) }
            }
        }
    }

    private func language(_ settings: GuildSettings) -> some View {
        SettingsGroup("Primary language") {
            SettingsCard {
                SettingsPickerRow(
                    title: "Language",
                    help: "Used in discovery and in the notices Discord sends you.",
                    options: GuildLocale.all.map { .init($0.code, $0.title) },
                    selection: Binding(
                        get: { settings.preferredLocale },
                        set: { saveCommunity(settings, locale: $0) }
                    )
                )
            }
        }
    }

    private func description(_ settings: GuildSettings) -> some View {
        SettingsGroup("Description") {
            SettingsCard {
                CommunityDescriptionField(settings: settings) { text in
                    saveCommunity(settings, description: .some(text))
                }
            }
            SettingsFootnote(
                "Shown on your server's listing and in invite previews. This is the "
                    + "same description as the one on Server Profile."
            )
        }
    }

    private func picker(
        _ title: String,
        help: String,
        selection: ChannelID?,
        set: @escaping @MainActor (ChannelID?) -> Void
    ) -> some View {
        SettingsPickerRow(
            title: title,
            help: help,
            options: [SettingsPickerRow<ChannelID?>.Option(nil, "None")]
                + store.textChannels.map { .init($0.id, "#\($0.name)") },
            selection: Binding(get: { selection }, set: set)
        )
    }

    /// The one save. Every argument defaults to what the server already holds,
    /// so a caller changes one and the other five go back unchanged — which is
    /// exactly what the route requires.
    private func saveCommunity(
        _ settings: GuildSettings,
        description: String?? = nil,
        locale: String? = nil,
        rules: ChannelID?? = nil,
        updates: ChannelID?? = nil,
        safety: ChannelID?? = nil
    ) {
        Task {
            await store.saveCommunitySettings(
                description: description ?? settings.description,
                // The whole set, unordered. Discord's own client spreads a `Set`
                // here and the order differs between two consecutive requests —
                // but the membership is load-bearing, and sending a subset
                // removes whatever was left out.
                features: settings.features,
                preferredLocale: locale ?? settings.preferredLocale,
                rulesChannelID: rules ?? settings.rulesChannelID,
                publicUpdatesChannelID: updates ?? settings.publicUpdatesChannelID,
                safetyAlertsChannelID: safety ?? settings.safetyAlertsChannelID
            )
        }
    }
}

/// Its own view so the draft text has somewhere to live across redraws.
private struct CommunityDescriptionField: View {
    var settings: GuildSettings
    var commit: (String?) -> Void

    @State private var text: String = ""

    var body: some View {
        EditableTextBlock(
            placeholder: "What is this server about?",
            text: $text,
            committed: settings.description ?? "",
            characterLimit: 300
        ) {
            commit(text.isEmpty ? nil : text)
        }
        .task(id: settings.description) { text = settings.description ?? "" }
    }
}

/// The languages Discord's own picker offers.
enum GuildLocale {
    struct Entry: Identifiable {
        var id: String { code }
        var code: String
        var title: String
    }

    static let all: [Entry] = [
        Entry(code: "en-US", title: "English, US"),
        Entry(code: "en-GB", title: "English, UK"),
        Entry(code: "bg", title: "Bulgarian"),
        Entry(code: "zh-CN", title: "Chinese, China"),
        Entry(code: "zh-TW", title: "Chinese, Taiwan"),
        Entry(code: "hr", title: "Croatian"),
        Entry(code: "cs", title: "Czech"),
        Entry(code: "da", title: "Danish"),
        Entry(code: "nl", title: "Dutch"),
        Entry(code: "fi", title: "Finnish"),
        Entry(code: "fr", title: "French"),
        Entry(code: "de", title: "German"),
        Entry(code: "el", title: "Greek"),
        Entry(code: "hi", title: "Hindi"),
        Entry(code: "hu", title: "Hungarian"),
        Entry(code: "id", title: "Indonesian"),
        Entry(code: "it", title: "Italian"),
        Entry(code: "ja", title: "Japanese"),
        Entry(code: "ko", title: "Korean"),
        Entry(code: "lt", title: "Lithuanian"),
        Entry(code: "no", title: "Norwegian"),
        Entry(code: "pl", title: "Polish"),
        Entry(code: "pt-BR", title: "Portuguese, Brazilian"),
        Entry(code: "ro", title: "Romanian"),
        Entry(code: "ru", title: "Russian"),
        Entry(code: "es-ES", title: "Spanish"),
        Entry(code: "es-419", title: "Spanish, LATAM"),
        Entry(code: "sv-SE", title: "Swedish"),
        Entry(code: "th", title: "Thai"),
        Entry(code: "tr", title: "Turkish"),
        Entry(code: "uk", title: "Ukrainian"),
        Entry(code: "vi", title: "Vietnamese"),
    ]
}

// MARK: - Onboarding

/// The questions and default channels a new member starts with.
///
/// **`in_onboarding` is the pre-join / post-join split**, which nothing in the
/// payload is named for. The capture has two prompts — one `true`, one `false` —
/// and Discord's editor shows exactly those two under "Pre-join Questions" and
/// "Post-join Questions" in that order. Read as "show this during the join flow"
/// the flag is the same fact said in a way that does not tell you where the
/// editor puts it.
///
/// **This page is read-only, deliberately.** `PUT /guilds/{id}/onboarding`
/// replaces the whole ballot — every prompt, every option, every role and
/// channel id — and no capture of that request exists. A save built from the
/// documentation alone that got one field wrong would not fail loudly; it would
/// wipe a server's prompts. The editing side waits for a capture, and §5.5 says
/// to state that rather than draw controls that might do it.
struct OnboardingPane: View {
    let store: ServerSettingsStore

    var body: some View {
        LoadableContent(store.onboarding) { onboarding in
            VStack(alignment: .leading, spacing: 0) {
                SettingsGroup {
                    SettingsCard {
                        SettingsValueRow(
                            title: "Onboarding",
                            value: onboarding.isEnabled ? "On" : "Off"
                        )
                        CardDivider()
                        SettingsValueRow(
                            title: "Default channels",
                            value: "\(onboarding.defaultChannelIDs.count)"
                        )
                    }
                }

                defaults(onboarding)
                questions(
                    "Pre-join questions",
                    detail: "Asked before somebody joins. These can assign channels and roles.",
                    prompts: onboarding.prompts.filter(\.isInOnboarding)
                )
                questions(
                    "Post-join questions",
                    detail: "Asked afterwards, on the Channels & Roles page.",
                    prompts: onboarding.prompts.filter { !$0.isInOnboarding }
                )

                SettingsFootnote(
                    "Wingcord reads onboarding and does not write it. Saving replaces "
                        + "the whole ballot in one request — every question, answer, "
                        + "role and channel — and this client has never seen that "
                        + "request made, so a wrong guess would not fail: it would "
                        + "erase the questions. Edit these in Discord's own client.",
                    symbolName: "info.circle"
                )
            }
        }
    }

    @ViewBuilder
    private func defaults(_ onboarding: GuildOnboarding) -> some View {
        if !onboarding.defaultChannelIDs.isEmpty {
            SettingsGroup("Default channels") {
                SettingsCard {
                    ForEach(Array(onboarding.defaultChannelIDs.enumerated()), id: \.element) { index, id in
                        if index > 0 { CardDivider() }
                        SettingsValueRow(
                            title: store.channelName(id).map { "#\($0)" } ?? "Unknown channel",
                            value: ""
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func questions(
        _ title: String,
        detail: String,
        prompts: [GuildOnboarding.Prompt]
    ) -> some View {
        if !prompts.isEmpty {
            SettingsGroup(title) {
                ForEach(prompts) { prompt in
                    SettingsCard {
                        VStack(alignment: .leading, spacing: Spacing.tight) {
                            Text(prompt.title)
                                .font(SettingsType.rowTitle)
                                .foregroundStyle(Ink.primary)
                            Text(qualifiers(prompt))
                                .font(SettingsType.rowSubtitle)
                                .foregroundStyle(Ink.secondary)
                        }
                        .padding(.horizontal, SettingsMetrics.cardContentInset)
                        .padding(.top, Spacing.snug)
                        .padding(.bottom, Spacing.base)

                        ForEach(prompt.options) { option in
                            CardDivider()
                            ObjectRow(
                                title: option.title,
                                subtitle: grants(option)
                            ) {
                                Text(option.emojiName ?? "•")
                                    .font(.system(size: 14))
                                    .frame(width: 28, height: 28)
                            }
                        }
                    }
                    .padding(.bottom, Spacing.base)
                }
                SettingsFootnote(detail)
            }
        }
    }

    private func qualifiers(_ prompt: GuildOnboarding.Prompt) -> String {
        var parts: [String] = []
        parts.append(prompt.isSingleSelect ? "One answer" : "Multiple answers")
        if prompt.isRequired { parts.append("required") }
        parts.append(prompt.options.count == 1 ? "1 answer" : "\(prompt.options.count) answers")
        return parts.joined(separator: " · ")
    }

    /// What choosing an option does. The member counts are why
    /// `roles/member-counts` is fetched at all — there is no other source.
    private func grants(_ option: GuildOnboarding.Option) -> String? {
        var parts: [String] = []
        if !option.channelIDs.isEmpty {
            let names = option.channelIDs.compactMap { store.channelName($0) }.map { "#\($0)" }
            if !names.isEmpty { parts.append(names.joined(separator: ", ")) }
        }
        for roleID in option.roleIDs {
            guard let role = store.roles.value?.first(where: { $0.id == roleID }) else { continue }
            if let count = store.roleMemberCounts[roleID] {
                parts.append("\(role.name) — \(count) chose this")
            } else {
                parts.append(role.name)
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Server Guide

/// The welcome, the first tasks and the pages new members are pointed at.
///
/// Read-only for the same reason onboarding is: `PUT
/// /guilds/{id}/new-member-welcome` replaces the whole guide, and no capture of
/// it exists.
///
/// **The welcome line carries `[@username]`**, which `ServerGuide.Welcome`
/// already substitutes — the reader's side of this client has done that since
/// the guide pages landed, and the editor confirms it from the other end: the
/// stored string is `"Hey [@username] hope you will enjoy the server!"` and
/// Discord's own editor renders "Hey @alex".
struct GuideSettingsPane: View {
    let store: ServerSettingsStore

    var body: some View {
        LoadableContent(store.serverGuide) { guide in
            VStack(alignment: .leading, spacing: 0) {
                SettingsGroup {
                    SettingsCard {
                        SettingsValueRow(
                            title: "Server Guide",
                            value: guide.isEnabled ? "On" : "Off"
                        )
                    }
                }

                if let welcome = guide.welcome {
                    SettingsGroup("Welcome message") {
                        SettingsCard {
                            Text(welcome.substituting("new member"))
                                .font(SettingsType.rowLabel)
                                .foregroundStyle(Ink.primary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(SettingsMetrics.cardContentInset)
                        }
                        SettingsFootnote(
                            "Each new member sees their own name where “new member” is here."
                        )
                    }
                }

                if !guide.actions.isEmpty {
                    SettingsGroup("New member tasks — \(guide.actions.count)") {
                        SettingsCard {
                            ForEach(Array(guide.actions.enumerated()), id: \.element.id) { index, action in
                                if index > 0 { CardDivider() }
                                ObjectRow(
                                    title: action.title,
                                    subtitle: store.channelName(action.channelID).map { "#\($0)" }
                                ) {
                                    Text(action.emojiName ?? "✓")
                                        .font(.system(size: 14))
                                        .frame(width: 28, height: 28)
                                }
                            }
                        }
                        SettingsFootnote("Discord asks for three to five of these.")
                    }
                }

                if !guide.resources.isEmpty {
                    SettingsGroup("Resource pages — \(guide.resources.count)") {
                        SettingsCard {
                            ForEach(Array(guide.resources.enumerated()), id: \.element.id) { index, resource in
                                if index > 0 { CardDivider() }
                                ObjectRow(
                                    title: resource.title,
                                    subtitle: resource.detail
                                        ?? store.channelName(resource.channelID).map { "#\($0)" }
                                ) {
                                    Image(systemName: "doc.text")
                                        .font(.system(size: 12))
                                        .foregroundStyle(Ink.secondary)
                                        .frame(width: 28, height: 28)
                                }
                            }
                        }
                    }
                }

                SettingsFootnote(
                    "Wingcord reads the guide and does not write it, for the same "
                        + "reason as onboarding: saving replaces the whole guide in "
                        + "one request this client has never seen made.",
                    symbolName: "info.circle"
                )
            }
        }
    }
}

// MARK: - Server Template

/// A server has **at most one**, which is why the route answers with an array
/// and this page is a form in two states rather than a list.
struct TemplatePane: View {
    let store: ServerSettingsStore

    @State private var name = ""
    @State private var detail = ""
    @State private var deleting = false
    @State private var copied = false

    var body: some View {
        LoadableContent(store.template) { template in
            VStack(alignment: .leading, spacing: 0) {
                copies

                SettingsGroup(template == nil ? "Create a template" : "Your template") {
                    SettingsCard {
                        EditableTextRow(
                            title: "Title",
                            placeholder: "My server",
                            text: $name,
                            committed: template?.name ?? ""
                        ) {
                            commit(template)
                        }
                        CardDivider()
                        EditableTextBlock(
                            placeholder: "What is this template for?",
                            text: $detail,
                            committed: template?.description ?? "",
                            characterLimit: 120
                        ) {
                            commit(template)
                        }
                    }
                }

                if let template {
                    link(template)
                } else {
                    HStack {
                        Spacer()
                        Button("Generate template") { commit(nil) }
                            .buttonStyle(.glassProminent)
                            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding(.top, Spacing.margin)
                }
            }
            .task(id: template?.id) {
                name = template?.name ?? ""
                detail = template?.description ?? ""
            }
        }
    }

    private var copies: some View {
        SettingsGroup {
            SettingsCard {
                HStack(alignment: .top, spacing: Spacing.group) {
                    list("Templates copy", items: GuildTemplate.copies, symbol: "checkmark.circle.fill", tint: Palette.affirmative)
                    list("They do not copy", items: GuildTemplate.doesNotCopy, symbol: "xmark.circle.fill", tint: Palette.destructive)
                }
                .padding(SettingsMetrics.cardContentInset)
            }
        }
    }

    private func list(_ title: String, items: [String], symbol: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            Text(title.uppercased())
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(Ink.tertiary)
            ForEach(items, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: Spacing.base) {
                    Image(systemName: symbol)
                        .font(.system(size: 11))
                        .foregroundStyle(tint)
                    Text(item)
                        .font(SettingsType.rowSubtitle)
                        .foregroundStyle(Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func link(_ template: GuildTemplate) -> some View {
        SettingsGroup("Link") {
            SettingsCard {
                SettingsControlRow("Template link") {
                    HStack(spacing: Spacing.base) {
                        Text(template.url?.absoluteString ?? template.id)
                            .font(SettingsType.rowLabel.monospaced())
                            .foregroundStyle(Ink.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button(copied ? "Copied" : "Copy") {
                            guard let url = template.url else { return }
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url.absoluteString, forType: .string)
                            copied = true
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                    }
                }
                CardDivider()
                SettingsValueRow(
                    title: "Used",
                    value: template.usageCount == 1 ? "once" : "\(template.usageCount) times"
                )
                // `is_dirty` is three-state: null means in step, true means
                // behind, and there is no false on the wire. So Sync is offered
                // on `true` alone rather than on "not false", which would offer
                // it always.
                if template.isDirty == true {
                    CardDivider()
                    SettingsActionRow(
                        "This template is behind your server",
                        actionTitle: "Sync"
                    ) {
                        Task { await store.syncTemplate(template.id) }
                    }
                }
                CardDivider()
                SettingsActionRow(
                    "Delete this template",
                    actionTitle: "Delete",
                    role: .destructive
                ) {
                    deleting = true
                }
            }
        }
        .destructiveConfirmation(
            isPresented: $deleting,
            title: "Delete this template?",
            message: "The link stops working for everybody who has it.",
            confirmTitle: "Delete"
        ) {
            Task { await store.deleteTemplate(template.id) }
        }
    }

    private func commit(_ template: GuildTemplate?) {
        let title = name.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        let blurb = detail.isEmpty ? nil : detail
        Task {
            if let template {
                await store.saveTemplate(template.id, name: title, description: blurb)
            } else {
                await store.createTemplate(name: title, description: blurb)
            }
        }
    }
}

// MARK: - The join application

/// The questions somebody answers before they are let in.
///
/// **Captured, unlike onboarding.** Turning "Apply to Join" on sent
/// `PATCH /guilds/{id}/member-verification` with `form_fields` and `enabled`, so
/// this one is editable — and `INVARIANTS.md` §5.5's rule that dimming has to be
/// re-earned when evidence arrives is why it is not read-only beside the two
/// pages above it.
struct JoinFormEditor: View {
    var form: JoinApplicationForm
    var commit: (JoinApplicationForm) -> Void

    @State private var draft: JoinApplicationForm?

    private var working: JoinApplicationForm { draft ?? form }

    var body: some View {
        SettingsGroup("Join application") {
            SettingsCard {
                ForEach(Array(working.fields.enumerated()), id: \.element.id) { index, field in
                    if index > 0 { CardDivider() }
                    row(field, at: index)
                }
                if working.fields.count < JoinApplicationForm.maximumQuestions {
                    CardDivider()
                    SettingsActionRow(
                        "Add a question",
                        actionTitle: "Add"
                    ) {
                        var next = working
                        next.fields.append(JoinApplicationForm.Field(label: ""))
                        draft = next
                    }
                }
            }

            HStack(spacing: Spacing.base) {
                Text("\(working.fields.count) of \(JoinApplicationForm.maximumQuestions) questions")
                    .font(.system(.caption).monospacedDigit())
                    .foregroundStyle(Ink.tertiary)
                Spacer()
                if isDirty {
                    Button("Revert") { draft = nil }
                        .buttonStyle(.plain)
                        .font(.system(.caption))
                        .foregroundStyle(Ink.tertiary)
                    Button("Save questions") {
                        var next = working
                        next.fields.removeAll {
                            $0.label.trimmingCharacters(in: .whitespaces).isEmpty
                        }
                        commit(next)
                        draft = nil
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }
            }
            .padding(.top, Spacing.base)

            if !working.canEnable {
                SettingsFootnote(
                    "An application with no questions cannot be turned on.",
                    symbolName: "exclamationmark.circle"
                )
            }
            if working.fields.isEmpty {
                exampleQuestions
            }
        }
    }

    private func row(_ field: JoinApplicationForm.Field, at index: Int) -> some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            HStack(spacing: Spacing.base) {
                TextField(
                    "Ask something…",
                    text: Binding(
                        get: { index < working.fields.count ? working.fields[index].label : "" },
                        set: { text in
                            var next = working
                            guard index < next.fields.count else { return }
                            next.fields[index].label = text
                            draft = next
                        }
                    )
                )
                .textFieldStyle(.plain)
                .font(SettingsType.rowLabel)
                .disabled(!field.kind.isEditable)

                Text(field.kind.title)
                    .font(.system(.caption))
                    .foregroundStyle(Ink.tertiary)

                RowIconButton(symbolName: "trash", label: "Remove question", role: .destructive) {
                    var next = working
                    guard index < next.fields.count else { return }
                    next.fields.remove(at: index)
                    draft = next
                }
            }
            if !field.kind.isEditable {
                // A field type this client has not seen is shown and carried
                // through a save untouched — dropping it would silently delete a
                // question somebody built in Discord's own client.
                Text("This question type is not editable here. It is kept as it is.")
                    .font(.system(.caption))
                    .foregroundStyle(Ink.tertiary)
            }
        }
        .padding(.horizontal, SettingsMetrics.cardContentInset)
        .padding(.vertical, Spacing.snug)
    }

    private var exampleQuestions: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            Text("EXAMPLE QUESTIONS")
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(Ink.tertiary)
            ForEach(JoinApplicationForm.exampleQuestions, id: \.self) { example in
                Button {
                    var next = working
                    next.fields.append(JoinApplicationForm.Field(label: example))
                    draft = next
                } label: {
                    Text(example)
                        .font(SettingsType.rowSubtitle)
                        .foregroundStyle(Ink.secondary)
                        .padding(.horizontal, Spacing.snug)
                        .padding(.vertical, 6)
                        .background(SettingsSurface.controlTrough, in: .capsule)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, Spacing.snug)
    }

    private var isDirty: Bool { draft != nil && draft?.fields != form.fields }
}
