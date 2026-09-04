import SwiftUI
import WingcordCore

// MARK: - Channels
//
// The page this window was most conspicuously missing: it could edit twenty
// things about a server and not rename a channel.
//
// Two facts shape it, and neither is guessable from the sheet's appearance:
//
//   1. **Private is not a field on the create.** The channel is made public and
//      an overwrite is applied afterwards — a denied `VIEW_CHANNEL` bit on
//      `@everyone`, whose role id is the guild's own.
//   2. **Deleting is refused before the request**, by Discord's own client,
//      where the channel is referenced by the Server Guide or by onboarding.
//      `ChannelDeleteGate` is that check; §SM.14 records that whether the
//      *server* would also refuse is unknown, which is exactly why this client
//      must not fire blind.

/// A channel's Overview page, as the editor holds it.
struct ChannelDraft: Hashable, Sendable, Identifiable {
    var id: ChannelID
    var name: String
    var kind: ChannelKind
    var topic: String
    var visibility: ChannelVisibility
    var bitrate: Int
    var userLimit: Int
    var slowmodeSeconds: Int
    var autoArchiveMinutes: Int?

    init(_ summary: ServerSettingsStore.ChannelSummary) {
        id = summary.id
        name = summary.name
        kind = summary.kind
        topic = ""
        visibility = .default
        // Discord's own defaults for a fresh channel. The Overview page sends
        // these on a *text* channel too, where they mean nothing — see §SM.14 —
        // so they need a value even here.
        bitrate = 64000
        userLimit = 0
        slowmodeSeconds = 0
        autoArchiveMinutes = nil
    }
}

struct ChannelsPane: View {
    let store: ServerSettingsStore

    @State private var creating = false
    @State private var editing: ChannelDraft?
    @State private var deleting: ServerSettingsStore.ChannelSummary?
    @State private var refusal: ChannelDeleteGate.Refusal?
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup {
                SettingsCard {
                    SettingsActionRow(
                        "Create a channel",
                        help: "Text, voice, forum, announcement, stage — or a category.",
                        actionTitle: "Create"
                    ) {
                        creating = true
                    }
                }
            }

            let shown = filtered
            SettingsGroup("Channels — \(store.channels.count)") {
                SettingsCard {
                    if store.channels.count > 6 {
                        SearchRow(query: $query, placeholder: "Search channels")
                        CardDivider()
                    }
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, channel in
                        if index > 0 { CardDivider() }
                        row(channel)
                    }
                }
            }
        }
        .sheet(isPresented: $creating) {
            CreateChannelSheet { name, kind, isPrivate in
                Task { await store.createChannel(name: name, kind: kind, isPrivate: isPrivate) }
            }
        }
        .sheet(item: $editing) { draft in
            ChannelSheet(draft: draft) { edited in
                Task { await store.saveChannel(edited) }
            }
        }
        // The refusal is its own alert rather than a disabled control, because
        // it is *conditional* — the same channel becomes deletable the moment
        // its guide task is removed, and a permanently dimmed trash tells
        // nobody why.
        .alert(
            "Cannot delete channel",
            isPresented: Binding(get: { refusal != nil }, set: { if !$0 { refusal = nil } })
        ) {
            Button("Okay", role: .cancel) {}
        } message: {
            Text(refusal?.message ?? "")
        }
    }

    private var filtered: [ServerSettingsStore.ChannelSummary] {
        guard !query.isEmpty else { return store.channels }
        let needle = query.lowercased()
        return store.channels.filter { $0.name.lowercased().contains(needle) }
    }

    private func row(_ channel: ServerSettingsStore.ChannelSummary) -> some View {
        ObjectRow(
            title: channel.name,
            subtitle: subtitle(channel),
            badge: channel.isPublic ? nil : "Private"
        ) {
            Image(systemName: symbol(channel.kind))
                .font(.system(size: 12))
                .foregroundStyle(Ink.secondary)
                .frame(width: 28, height: 28)
                .background(SettingsSurface.controlTrough, in: .circle)
        } trailing: {
            HStack(spacing: 2) {
                RowIconButton(
                    symbolName: channel.isPublic ? "lock.open" : "lock.fill",
                    label: channel.isPublic ? "Make \(channel.name) private" : "Make \(channel.name) public"
                ) {
                    Task { await store.setChannelPrivate(channel.id, isPrivate: channel.isPublic) }
                }
                RowIconButton(symbolName: "pencil", label: "Edit \(channel.name)") {
                    editing = ChannelDraft(channel)
                }
                RowIconButton(
                    symbolName: "trash",
                    label: "Delete \(channel.name)",
                    role: .destructive
                ) {
                    // The gate runs before the confirmation, not after it: a
                    // reader should not be asked to confirm something that will
                    // then be refused.
                    if let reason = store.deleteRefusal(for: channel.id) {
                        refusal = reason
                    } else {
                        deleting = channel
                    }
                }
            }
        }
        .destructiveConfirmation(
            isPresented: Binding(
                get: { deleting?.id == channel.id },
                set: { if !$0 { deleting = nil } }
            ),
            title: "Delete #\(channel.name)?",
            message: channel.kind == .category
                ? "The channels inside it are kept and move out of the category."
                : "Every message in it goes with it. This cannot be undone.",
            confirmTitle: "Delete"
        ) {
            Task { await store.deleteChannel(channel.id) }
        }
    }

    private func subtitle(_ channel: ServerSettingsStore.ChannelSummary) -> String? {
        var parts: [String] = [kindTitle(channel.kind)]
        if let category = channel.categoryName { parts.append("in \(category)") }
        return parts.joined(separator: " · ")
    }

    private func kindTitle(_ kind: ChannelKind) -> String {
        switch kind {
        case .text: "Text"
        case .voice: "Voice"
        case .category: "Category"
        case .announcement: "Announcement"
        case .forum: "Forum"
        case .stage: "Stage"
        case .media: "Media"
        default: "Channel"
        }
    }

    private func symbol(_ kind: ChannelKind) -> String {
        switch kind {
        case .voice: "speaker.wave.2.fill"
        case .category: "folder.fill"
        case .announcement: "megaphone.fill"
        case .forum: "list.bullet.rectangle"
        case .stage: "person.wave.2.fill"
        case .media: "photo.fill"
        default: "number"
        }
    }
}

// MARK: - Creating

/// The five kinds the sheet offers, plus a category.
///
/// **A category is the same route with `type: 4`** — captured, and not a
/// separate endpoint. So it is one sheet, and the Private switch works the same
/// on both: the capture toggling a category's privacy sent exactly the overwrite
/// a channel's does.
struct CreateChannelSheet: View {
    var commit: (String, ChannelKind, Bool) -> Void

    @State private var name = ""
    @State private var kind: ChannelKind = .text
    @State private var isPrivate = false

    private static let kinds: [(ChannelKind, String, String)] = [
        (.text, "Text", "Send messages, images, GIFs, emoji, opinions and puns."),
        (.voice, "Voice", "Hang out together with voice, video and screen share."),
        (.forum, "Forum", "A space for organised discussions."),
        (.announcement, "Announcement", "Important updates people can follow in their own servers."),
        (.stage, "Stage", "Host events, panels and Q&As for an audience."),
        (.category, "Category", "A group other channels sit inside."),
    ]

    var body: some View {
        SheetFrame(
            title: "Create a channel",
            confirmTitle: "Create",
            canConfirm: !name.trimmingCharacters(in: .whitespaces).isEmpty
        ) {
            commit(name.trimmingCharacters(in: .whitespaces), kind, isPrivate)
        } content: {
            SheetField(title: "Type", isRequired: true) {
                VStack(alignment: .leading, spacing: Spacing.base) {
                    ForEach(Self.kinds, id: \.0) { entry in
                        ChannelKindChoice(
                            title: entry.1,
                            detail: entry.2,
                            isSelected: kind == entry.0
                        ) {
                            kind = entry.0
                        }
                    }
                }
            }

            SheetField(title: "Name", isRequired: true) {
                TextField("new-channel", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            SheetField(
                title: kind == .category ? "Private category" : "Private channel",
                detail: kind == .category
                    ? "Only selected members and roles will see it. Channels inside "
                        + "it match this setting."
                    : "Only selected members and roles will be able to view this channel."
            ) {
                Toggle("", isOn: $isPrivate)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
            }
        }
    }
}

private struct ChannelKindChoice: View {
    var title: String
    var detail: String
    var isSelected: Bool
    var choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack(alignment: .top, spacing: Spacing.snug) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(Ink.tertiary))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(.subheadline, weight: .medium))
                        .foregroundStyle(Ink.primary)
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
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

// MARK: - Editing

/// The Overview page.
///
/// Every control here maps to one of the eight fields the route takes whole —
/// and **Content Visibility maps to two of them**, which is the thing about this
/// page that is easy to get wrong. `ChannelVisibility` is one enum in the model
/// and `nsfw` plus a flag bit at the encoder, which is the only arrangement that
/// is right in both places.
struct ChannelSheet: View {
    var draft: ChannelDraft
    var commit: (ChannelDraft) -> Void

    @State private var working: ChannelDraft

    init(draft: ChannelDraft, commit: @escaping (ChannelDraft) -> Void) {
        self.draft = draft
        self.commit = commit
        _working = State(initialValue: draft)
    }

    private var isVoice: Bool { working.kind == .voice || working.kind == .stage }
    private var isTextLike: Bool {
        working.kind == .text || working.kind == .announcement || working.kind == .forum
    }

    var body: some View {
        SheetFrame(
            title: "Edit #\(draft.name)",
            confirmTitle: "Save",
            canConfirm: !working.name.trimmingCharacters(in: .whitespaces).isEmpty
                && working != draft
        ) {
            commit(working)
        } content: {
            SheetField(title: "Name", isRequired: true) {
                TextField("channel-name", text: $working.name)
                    .textFieldStyle(.roundedBorder)
            }

            if isTextLike {
                SheetField(title: "Topic") {
                    TextField("", text: $working.topic, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(3...6)
                }

                SheetField(title: "Content visibility") {
                    VStack(alignment: .leading, spacing: Spacing.base) {
                        ForEach(ChannelVisibility.allCases) { candidate in
                            ChannelKindChoice(
                                title: candidate.title,
                                detail: candidate.detail,
                                isSelected: working.visibility == candidate
                            ) {
                                working.visibility = candidate
                            }
                        }
                    }
                }

                SheetField(
                    title: "Announcement channel",
                    detail: "People can follow this channel in their own servers. "
                        + "Turning this on changes the channel's type."
                ) {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { working.kind == .announcement },
                            // The switch **rewrites `type`**, 0 ⇄ 5. It is the
                            // only place in this client a channel's kind is
                            // mutable, and it is a captured fact rather than an
                            // inference.
                            set: { working.kind = $0 ? .announcement : .text }
                        )
                    )
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                }

                SheetField(
                    title: "Hide after inactivity",
                    detail: "New threads leave the channel list after this long."
                ) {
                    Picker("", selection: $working.autoArchiveMinutes) {
                        Text("Server default").tag(Int?.none)
                        ForEach(ThreadArchiveDuration.minutes, id: \.self) { value in
                            Text(ThreadArchiveDuration.title(value)).tag(Int?.some(value))
                        }
                    }
                    .labelsHidden()
                }

                SheetField(title: "Slowmode", detail: "How long between one member's messages.") {
                    Picker("", selection: $working.slowmodeSeconds) {
                        ForEach(Self.slowmodeChoices, id: \.self) { value in
                            Text(Self.slowmodeTitle(value)).tag(value)
                        }
                    }
                    .labelsHidden()
                }
            }

            if isVoice {
                SheetField(title: "Bitrate", detail: "Higher sounds better and costs more bandwidth.") {
                    Picker("", selection: $working.bitrate) {
                        ForEach([8000, 32000, 64000, 96000, 128000], id: \.self) { value in
                            Text("\(value / 1000) kbps").tag(value)
                        }
                    }
                    .labelsHidden()
                }

                SheetField(title: "User limit", detail: "Zero is no limit.") {
                    Picker("", selection: $working.userLimit) {
                        ForEach([0, 2, 5, 10, 25, 50, 99], id: \.self) { value in
                            Text(value == 0 ? "No limit" : "\(value)").tag(value)
                        }
                    }
                    .labelsHidden()
                }
            }
        }
    }

    private static let slowmodeChoices = [0, 5, 10, 15, 30, 60, 120, 300, 600, 900, 3600, 21600]

    private static func slowmodeTitle(_ seconds: Int) -> String {
        switch seconds {
        case 0: "Off"
        case ..<60: "\(seconds) seconds"
        case ..<3600: "\(seconds / 60) minutes"
        default: "\(seconds / 3600) hours"
        }
    }
}
