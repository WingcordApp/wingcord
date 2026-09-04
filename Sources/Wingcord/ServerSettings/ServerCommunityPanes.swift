import AppKit
import SwiftUI
import WingcordCore
import WingcordNet

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
    /// Turning community on — see `EnableCommunityCard`.
    private var notCommunity: some View {
        EnableCommunityCard(store: store)
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
/// The editor is `OnboardingEditor`. This page was read-only for two releases
/// on a reason that turned out to be wrong: it said the PUT "replaces the whole
/// ballot" and that a partial save would erase a server's questions.
/// `community and onboarding.har` shows it **merges per field** — one request
/// carrying only `default_channel_ids` left the prompts alone, one carrying only
/// `prompts` left the channels alone, and one carrying only `enabled` left both.
/// HANDOFF §SM.11 has the correction and the two things a new prompt needs: a
/// client-minted millisecond-timestamp id, and its emoji sent twice.
struct OnboardingPane: View {
    let store: ServerSettingsStore

    var body: some View {
        LoadableContent(store.onboarding) { onboarding in
            OnboardingEditor(store: store, onboarding: onboarding)
        }
    }
}

// MARK: - Server Guide

/// The welcome, the first tasks and the pages new members are pointed at.
///
/// Read-only because the editor is not written. The route **is** captured, and
/// unlike onboarding it really is a whole-object replace — the second captured
/// PUT re-sends both tasks to add one. `guild_id` goes in the body and an absent
/// emoji is `{}`. HANDOFF §SM.11.
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
            GuideEditor(store: store, guide: guide)
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
/// Turning "Apply to Join" on sent `PATCH /guilds/{id}/member-verification` with
/// `form_fields` and `enabled`. This was the first page on the surface to become
/// editable when its capture arrived, which is `INVARIANTS.md` §5.5's rule that
/// dimming has to be re-earned; onboarding and the guide followed later for the
/// same reason.
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

// MARK: - Turning Community on

/// The wizard, as one card.
///
/// **Six fields in one request**, and the trick is one literal: `"1"` in a
/// channel field is a sentinel meaning *create one for me* rather than a channel
/// id — Discord makes `#rules` or `#moderator-only` and links it. That is the
/// wizard's "Create one for me" option, and it is why the two pickers take an
/// enum rather than an optional id.
///
/// Discord's own flow is three steps. It is one card here because the three are
/// two checkboxes, two pickers and an agreement — a paging control for five
/// fields is paging for its own sake, and the Review step reviews a form the
/// reader can already see.
struct EnableCommunityCard: View {
    let store: ServerSettingsStore

    @State private var rules: DiscordREST.CommunityChannel = .createForMe
    @State private var updates: DiscordREST.CommunityChannel = .createForMe
    @State private var hasAgreed = false

    /// Discord requires both before it will convert. They are checkboxes rather
    /// than an implicit part of the save, because turning them on changes what
    /// members may do — and doing that silently on somebody's behalf is not the
    /// client's call.
    @State private var requiresVerifiedEmail = true
    @State private var scansAllMedia = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup {
                SettingsCard {
                    VStack(alignment: .leading, spacing: Spacing.base) {
                        Text("This server is not a Community server.")
                            .font(SettingsType.rowTitle)
                            .foregroundStyle(Ink.primary)
                        Text(
                            "Community brings a rules channel, onboarding, a Server "
                                + "Guide and Discord's safety notices. It does not put "
                                + "your server in Server Discovery."
                        )
                        .font(SettingsType.rowSubtitle)
                        .foregroundStyle(Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(SettingsMetrics.cardContentInset)
                }
            }

            SettingsGroup("Safety checks") {
                SettingsCard {
                    SettingsToggle(
                        title: "Members must have a verified email",
                        help: "Members with a role are exempt.",
                        isOn: $requiresVerifiedEmail
                    )
                    CardDivider()
                    SettingsToggle(
                        title: "Scan media from all members",
                        help: "Discord deletes explicit media. Age-restricted "
                            + "channels are exempt.",
                        isOn: $scansAllMedia
                    )
                }
                SettingsFootnote("Discord requires both before a server can convert.")
            }

            SettingsGroup("Channels") {
                SettingsCard {
                    channelPicker("Rules or guidelines", selection: $rules)
                    CardDivider()
                    channelPicker("Community updates", selection: $updates)
                }
                SettingsFootnote(
                    "Choosing “Create one for me” has Discord make the channel and "
                        + "link it — that is a real option on the route, not this "
                        + "client filling in a blank."
                )
            }

            SettingsGroup("Agree") {
                SettingsCard {
                    SettingsToggle(
                        title: "This server follows Discord's Community Guidelines",
                        isOn: $hasAgreed
                    )
                }
            }

            HStack {
                Spacer()
                Button("Enable Community") {
                    Task {
                        await store.enableCommunity(
                            rules: rules,
                            updates: updates,
                            // The two checkboxes above, in the values Discord's
                            // own wizard sends: a verified email is verification
                            // level 1, and scanning everybody is filter 2.
                            verification: requiresVerifiedEmail ? .low : .none,
                            notifications: .onlyMentions,
                            explicitContent: scansAllMedia ? .allMembers : .disabled
                        )
                    }
                }
                .buttonStyle(.glassProminent)
                .disabled(!hasAgreed || !requiresVerifiedEmail || !scansAllMedia)
            }
            .padding(.top, Spacing.margin)
        }
    }

    private func channelPicker(
        _ title: String,
        selection: Binding<DiscordREST.CommunityChannel>
    ) -> some View {
        SettingsControlRow(title) {
            Menu {
                Button("Create one for me") { selection.wrappedValue = .createForMe }
                Divider()
                ForEach(store.textChannels) { channel in
                    Button("#\(channel.name)") {
                        selection.wrappedValue = .existing(channel.id)
                    }
                }
            } label: {
                Text(label(selection.wrappedValue))
                    .font(SettingsType.rowLabel)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private func label(_ channel: DiscordREST.CommunityChannel) -> String {
        switch channel {
        case .createForMe: "Create one for me"
        case .existing(let id): store.channelName(id).map { "#\($0)" } ?? "Choose"
        }
    }
}
