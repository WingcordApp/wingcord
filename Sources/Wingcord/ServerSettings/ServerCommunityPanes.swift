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

    @State private var isDisabling = false

    /// Discord's Community Overview (`cw`) for a Community server, and its
    /// Enable Community page (`cL`) for one that is not yet. Every word is
    /// Discord's; each control saves as it changes.
    var body: some View {
        LoadableContent(store.settings) { settings in
            VStack(alignment: .leading, spacing: 0) {
                if settings.isCommunity {
                    communitySettings(settings)
                    disableCommunity(settings)
                } else {
                    EnableCommunityPitch()
                    EnableCommunityCard(store: store)
                }
            }
        }
    }

    // MARK: Community Settings

    private func communitySettings(_ settings: GuildSettings) -> some View {
        let isAdmin = store.permissions.contains(.administrator)
        return VStack(alignment: .leading, spacing: 0) {
            SettingsGroup("Community Settings") {
                SettingsCard {
                    DescribedRow(
                        "Rules or guidelines channel",
                        detail: Text("Please select the channel that hosts your rules. This channel will by default start from the top and will feature a special header.")
                    ) {
                        channelPicker(settings.rulesChannelID, title: "Rules or guidelines channel") {
                            saveCommunity(settings, rules: .some($0))
                        }
                    }
                    CardDivider()
                    DescribedRow(
                        "Community Updates Channel",
                        detail: Text("This is the channel where Discord will send relevant updates for Community admins and moderators. As some info might be sensitive, we recommend selecting a role-restricted channel.")
                    ) {
                        // Discord lets only an administrator move it.
                        channelPicker(settings.publicUpdatesChannelID, title: "Community Updates Channel", isEnabled: isAdmin) {
                            saveCommunity(settings, updates: .some($0))
                        }
                    }
                    CardDivider()
                    DescribedRow(
                        "Safety Notifications Channel",
                        detail: Text("This is the channel where Discord will send you important safety updates about your server. As some info might be sensitive, we recommend selecting a role-restricted channel.")
                    ) {
                        channelPicker(settings.safetyAlertsChannelID, title: "Safety Notifications Channel") {
                            saveCommunity(settings, safety: .some($0))
                        }
                    }
                    CardDivider()
                    DescribedRow(
                        "Server Primary Language",
                        detail: Text("This helps Discord customize features for you and your members.")
                    ) {
                        FlyoutPicker(
                            selection: Binding(
                                get: { settings.preferredLocale },
                                set: { saveCommunity(settings, locale: $0) }
                            ),
                            options: GuildLocale.all.map(\.code),
                            title: { code in GuildLocale.all.first { $0.code == code }?.title ?? code },
                            accessibilityTitle: "Server Primary Language"
                        )
                    }
                }
            }
            SettingsGroup("Server Description") {
                Text("Describe your community. This description will be displayed in external embeds of this server\u{2019}s invite link.")
                    .font(SettingsType.rowSubtitle)
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, Spacing.snug)
                SettingsCard {
                    CommunityDescriptionField(settings: settings) { text in
                        saveCommunity(settings, description: .some(text))
                    }
                }
            }
        }
    }

    private func disableCommunity(_ settings: GuildSettings) -> some View {
        let isAdmin = store.permissions.contains(.administrator)
        return SettingsGroup {
            SettingsCard {
                DescribedRow(
                    "Disable Community",
                    detail: Text("This will remove specific features for Community Servers, like Server Discovery and Server Insights.")
                ) {
                    Button("Disable Community", role: .destructive) {
                        // Discord asks only where it would also leave Discovery.
                        if settings.features.contains("DISCOVERABLE") {
                            isDisabling = true
                        } else {
                            disable(settings)
                        }
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .tint(Palette.destructive)
                    .disabled(!isAdmin)
                    .help(isAdmin ? "" : "Only server administrators are allowed to do this")
                }
            }
        }
        .modal(isPresented: $isDisabling, style: .alert) {
            ModalAlert(
                hero: .symbol("person.3.sequence.fill"),
                title: "Are you sure?",
                message: Text("Disabling Community will also remove your server from Server Discovery."),
                actions: [
                    .cancel("Never Mind"),
                    .act("Confirm", symbol: "checkmark", irreversible: true) { disable(settings) },
                ]
            )
        }
    }

    /// Discord's `r`: the community features off, and the two channels it
    /// set up released.
    private func disable(_ settings: GuildSettings) {
        var features = settings.features
        features.remove("COMMUNITY")
        features.remove("DISCOVERABLE")
        features.remove("PREVIEW_ENABLED")
        Task {
            await store.saveCommunitySettings(
                description: settings.description,
                features: features,
                preferredLocale: settings.preferredLocale,
                rulesChannelID: nil,
                publicUpdatesChannelID: nil,
                safetyAlertsChannelID: settings.safetyAlertsChannelID
            )
        }
    }

    private func channelPicker(
        _ selection: ChannelID?,
        title: String,
        isEnabled: Bool = true,
        set: @escaping @MainActor (ChannelID?) -> Void
    ) -> some View {
        FlyoutPicker(
            selection: Binding(get: { selection }, set: set),
            options: [nil] + store.textChannels.filter { $0.kind == .text }.map { Optional($0.id) },
            title: { id in id.flatMap { store.channelName($0) }.map { "#\($0)" } ?? "Select..." },
            accessibilityTitle: title,
            isEnabled: isEnabled
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

/// Discord's Enable Community page (`cL`): what a Community Server is and
/// what it gives, in its words, over the wizard that turns it on.
private struct EnableCommunityPitch: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.snug) {
            Text("Are you building a Community?")
                .font(.system(.title3, weight: .semibold))
                .foregroundStyle(Ink.primary)
            Text("Convert to a Community Server to access additional administrative tools that help you moderate and grow your server. [Learn more.](https://support.discord.com/hc/en-us/articles/14078261239831)")
                .font(SettingsType.rowSubtitle)
                .foregroundStyle(Ink.secondary)
                .tint(Palette.accent)
                .fixedSize(horizontal: false, vertical: true)
            Text("Community Servers are larger spaces where people with shared interests can come together.")
                .font(SettingsType.rowSubtitle)
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Enabling Community does not make your server visible on Server Discovery. [Learn more here.](https://support.discord.com/hc/en-us/articles/360047132851)")
                .font(SettingsType.rowSubtitle)
                .foregroundStyle(Ink.secondary)
                .tint(Palette.accent)
                .fixedSize(horizontal: false, vertical: true)
            SettingsCard {
                benefit("Grow your community", Text("Apply to be in \(Text("Server Discovery").bold()) so more people can find your server directly on Discord."), tint: .green)
                CardDivider()
                benefit("Keep members engaged", Text("Access tools like \(Text("Server Insights").bold()) that can better help you moderate and keep your server engaged."), tint: .purple)
                CardDivider()
                benefit("Stay informed", Text("Get direct updates about new features built for communities from Discord."), tint: .red)
            }
            .padding(.top, Spacing.snug)
        }
        .padding(.bottom, SettingsMetrics.cardToHeader)
    }

    private func benefit(_ title: String, _ detail: Text, tint: Color) -> some View {
        DescribedRow(title, detail: detail) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
        } trailing: {
            EmptyView()
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
            placeholder: "Tell the world a bit about this server.",
            text: $text,
            committed: settings.description ?? "",
            characterLimit: 300
        ) {
            commit(text.isEmpty ? nil : text)
        }
        .task(id: settings.description) { text = settings.description ?? "" }
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

                SettingsGroup {
                    SettingsCard {
                        EditableTextRow(
                            title: "Template Title",
                            placeholder: "Who is this server for? E.g. School Club, Artists\u{2019} Community",
                            text: $name,
                            committed: template?.name ?? ""
                        ) {
                            commit(template)
                        }
                        CardDivider()
                        EditableTextBlock(
                            placeholder: "What can people do in this server?",
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
                        Button("Generate Template") { commit(nil) }
                            .buttonStyle(.glassProminent)
                            .buttonBorderShape(.capsule)
                            .tint(Palette.accent)
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
                    list("Templates will copy:", items: GuildTemplate.copies, symbol: "checkmark.circle.fill", tint: Palette.affirmative)
                    list("Templates will not copy:", items: GuildTemplate.doesNotCopy, symbol: "xmark.circle.fill", tint: Palette.destructive)
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
                    Image(symbol: symbol)
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
        SettingsGroup {
            SettingsCard {
                SettingsControlRow("Template Link") {
                    HStack(spacing: Spacing.base) {
                        Text(template.url?.absoluteString ?? template.id)
                            .font(SettingsType.rowLabel.monospaced())
                            .foregroundStyle(Ink.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button(copied ? "Copied!" : "Copy") {
                            guard let url = template.url else { return }
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url.absoluteString, forType: .string)
                            copied = true
                        }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                    }
                }
                // `is_dirty` is three-state: null means in step, true means
                // behind, and there is no false on the wire. So Sync is offered
                // on `true` alone rather than on "not false", which would offer
                // it always.
                if template.isDirty == true {
                    CardDivider()
                    SettingsActionRow(
                        "* You have unsynced changes. Update the channels, roles, and permissions in your template by syncing.",
                        actionTitle: "Sync Template"
                    ) {
                        Task { await store.syncTemplate(template.id) }
                    }
                }
                CardDivider()
                SettingsActionRow(
                    "Delete Template",
                    actionTitle: "Delete Template",
                    role: .destructive
                ) {
                    deleting = true
                }
            }
        }
        .destructiveConfirmation(
            isPresented: $deleting,
            title: "Delete Template",
            message: "Are you sure you want to delete your template? This will prevent anyone with the link from using it.",
            confirmTitle: "Delete Template"
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
    @State private var mentionsOnly = true
    @State private var removesRiskyPermissions = true

    /// Discord requires both before it will convert. They are checkboxes rather
    /// than an implicit part of the save, because turning them on changes what
    /// members may do — and doing that silently on somebody's behalf is not the
    /// client's call.
    @State private var requiresVerifiedEmail = true
    @State private var scansAllMedia = true

    /// Discord's three steps (`416def23`), in its words, on one page: Safety
    /// checks, Setting up the basics, Finishing touches.
    var body: some View {
        let settings = store.settings.value
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup("Safety checks") {
                Text("To ensure user safety, Community Servers must have the following moderation settings enabled.")
                    .font(SettingsType.rowSubtitle)
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, Spacing.snug)
                SettingsCard {
                    DescribedRow(
                        "Verified email required.",
                        detail: Text((settings?.verificationLevel.rawValue ?? 0) >= VerificationLevel.low.rawValue
                            ? "Your server already meets or exceeds the verification level requirement."
                            : "To minimize spam, members of the server must have a verified email before they can send messages. This does not apply to members with roles.")
                    ) {
                        Toggle("Verified email required.", isOn: $requiresVerifiedEmail)
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                    }
                    CardDivider()
                    DescribedRow(
                        "Explicit Media Content Filter",
                        detail: Text(settings?.explicitContentFilter == .allMembers
                            ? "Your server already meets the media content filter requirement."
                            : "Discord will automatically scan and delete media sent in this server that contain explicit content (excludes age-restricted channels).")
                    ) {
                        Toggle("Scan media content from all members.", isOn: $scansAllMedia)
                            .toggleStyle(.checkbox)
                    }
                }
            }

            SettingsGroup("Setting up the basics") {
                Text("Tell us which channel has your server rules and which channel we should send announcements to!")
                    .font(SettingsType.rowSubtitle)
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, Spacing.snug)
                SettingsCard {
                    DescribedRow(
                        "Rules or Guidelines Channel",
                        detail: Text("Community Servers must have clearly posted server rules and/or guidelines for members. Please select the channel that hosts this.")
                    ) {
                        channelPicker("Rules or Guidelines Channel", selection: $rules)
                    }
                    CardDivider()
                    DescribedRow(
                        "Community Updates Channel",
                        detail: Text("This is the channel where Discord will send relevant updates for Community admins and moderators. As some info might be sensitive, we recommend selecting a role-restricted channel.")
                    ) {
                        channelPicker("Community Updates Channel", selection: $updates)
                    }
                }
            }

            SettingsGroup("Finishing touches") {
                Text("You\u{2019}re almost there! Here are some suggestions to help create a better experience for your members.")
                    .font(SettingsType.rowSubtitle)
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, Spacing.snug)
                SettingsCard {
                    Toggle(isOn: $mentionsOnly) {
                        HStack(spacing: Spacing.tight) {
                            Text("Set default settings to Mentions Only")
                            InfoGlyph(help: "Because Community Servers tend to have a lot of people talking at once, defaulting Server Notifications for members to Mentions Only can help reduce members leaving. Members can always override this option.")
                        }
                    }
                    .toggleStyle(.checkbox)
                    .padding(SettingsMetrics.cardContentInset)
                    CardDivider()
                    Toggle(isOn: $removesRiskyPermissions) {
                        HStack(spacing: Spacing.tight) {
                            Text("Remove moderation permissions from @everyone")
                            InfoGlyph(help: "This will remove the following permissions from the @everyone role: Administrator, Manage Server, Manage Channels, Manage Roles, Kick Members, Ban Members, Manage Messages, and Mention @everyone, @here, and All Roles.")
                        }
                    }
                    .toggleStyle(.checkbox)
                    .padding(SettingsMetrics.cardContentInset)
                    CardDivider()
                    DescribedRow(
                        "Follow the rules",
                        detail: Text("By setting your server as a Community Server, you agree that your server complies with our [Community Server Guidelines](https://support.discord.com/hc/en-us/articles/360035969312). Learn more about [Community Servers](https://support.discord.com/hc/en-us/articles/14078261239831).")
                    ) {
                        Toggle("I agree and understand", isOn: $hasAgreed)
                            .toggleStyle(.checkbox)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Finish Setup") {
                    Task {
                        if removesRiskyPermissions { await store.removeRiskyPermissions() }
                        await store.enableCommunity(
                            rules: rules,
                            updates: updates,
                            // The checkboxes above, in the values Discord's own
                            // wizard sends: a verified email is verification
                            // level 1, and scanning everybody is filter 2.
                            verification: requiresVerifiedEmail ? atLeastLow(settings?.verificationLevel) : (settings?.verificationLevel ?? .none),
                            notifications: mentionsOnly ? .onlyMentions : (settings?.defaultMessageNotifications ?? .allMessages),
                            explicitContent: scansAllMedia ? .allMembers : (settings?.explicitContentFilter ?? .disabled)
                        )
                    }
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .tint(Palette.accent)
                .disabled(!hasAgreed || !requiresVerifiedEmail || !scansAllMedia)
            }
            .padding(.top, Spacing.margin)
        }
    }

    /// A verified email at the least — a stricter level the server already
    /// has is kept, as Discord's wizard keeps it.
    private func atLeastLow(_ current: VerificationLevel?) -> VerificationLevel {
        guard let current, current.rawValue > VerificationLevel.low.rawValue else { return .low }
        return current
    }

    private func channelPicker(
        _ title: String,
        selection: Binding<DiscordREST.CommunityChannel>
    ) -> some View {
        FlyoutPicker(
            selection: selection,
            options: [.createForMe] + store.textChannels.filter { $0.kind == .text }.map { .existing($0.id) },
            title: label,
            accessibilityTitle: title
        )
    }

    private func label(_ channel: DiscordREST.CommunityChannel) -> String {
        switch channel {
        case .createForMe: "Create one for me"
        case .existing(let id): store.channelName(id).map { "#\($0)" } ?? "Select..."
        }
    }
}
