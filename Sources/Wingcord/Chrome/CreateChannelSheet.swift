import SwiftUI
import WingcordCore

/// Discord's Create Channel and Create Category (`58d759f5`), from the server
/// menu, a category, or a channel's own menu.
///
/// **Every word is Discord's**: the two titles and "in {category}" under them,
/// "Channel Type" and each type's line, "Channel Name" with its placeholder,
/// the private switch and its sentence, and the announcement note.
///
/// **The name is written as Discord writes it while it is typed** — a text
/// channel's spaces become dashes and its capitals go, as they do in the
/// modal — so what is created is what was on screen.
struct CreateChannelSheet: View {
    var request: ChannelCreationRequest

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var kind: ChannelKind
    @State private var name = ""
    @State private var isPrivate = false
    @State private var isWorking = false
    @State private var failure: String?

    init(request: ChannelCreationRequest) {
        self.request = request
        _kind = State(initialValue: request.kind)
        _name = State(initialValue: request.duplicating?.name ?? "")
    }

    private var isCategory: Bool { request.kind == .category }

    private var title: String {
        if request.duplicating != nil { return "Duplicate Channel" }
        return isCategory ? "Create Category" : "Create Channel"
    }

    var body: some View {
        FormSheet(
            title: title,
            subtitle: categoryName.map { Text(verbatim: "in \($0)") },
            confirmTitle: isCategory ? "Create Category" : "Create Channel",
            isWorking: isWorking,
            canConfirm: !name.trimmingCharacters(in: .whitespaces).isEmpty,
            confirm: create
        ) {
            // A duplicate's type is the original's, and its permissions are
            // copied: no type list and no privacy switch, as in Discord's.
            if request.duplicating == nil, !isCategory { typePicker }
            nameField
            if let source = request.duplicating {
                // The name field's helper line in Discord's.
                Text("A new channel will be created with the same permissions, user limit and bitrate as **\(source.name)**.")
                    .font(.system(.caption))
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if request.duplicating == nil, ChannelCreation.offersPrivacy(kind) { privacySwitch }
            if kind == .announcement {
                Text("Users can Follow this channel in their own servers. Posts you \u{201C}Publish\u{201D} from this channel will appear in those servers. [Learn more.](https://support.discord.com/hc/en-us/articles/360032008192)")
                    .font(.system(.caption))
                    .foregroundStyle(Ink.secondary)
                    .tint(Palette.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let failure {
                Callout(text: failure, symbolName: "exclamationmark.triangle.fill", tint: Palette.destructive)
            }
        }
    }

    // MARK: Fields

    private var typePicker: some View {
        SheetField(title: "Channel Type") {
            VStack(spacing: Spacing.tight) {
                ForEach(ChannelCreation.kinds(features: model.guilds[request.guildID]?.features ?? []), id: \.self) { candidate in
                    ChannelTypeOption(
                        kind: candidate,
                        isPrivate: isPrivate,
                        isSelected: kind == candidate
                    ) {
                        kind = candidate
                        name = ChannelCreation.sanitizedName(name, for: candidate)
                        if !ChannelCreation.offersPrivacy(candidate) { isPrivate = false }
                    }
                }
            }
        }
    }

    private var nameField: some View {
        SheetField(title: isCategory ? "Category Name" : "Channel Name") {
            HStack(spacing: Spacing.base) {
                if !isCategory {
                    Image(symbol: kind.symbolName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Ink.secondary)
                        .accessibilityHidden(true)
                }
                TextField(placeholder, text: $name)
                    .textFieldStyle(.plain)
                    .onChange(of: name) { _, typed in
                        let written = String(ChannelCreation.sanitizedName(typed, for: kind).prefix(ChannelCreation.nameLimit))
                        if written != typed { name = written }
                    }
            }
            .padding(.horizontal, Spacing.snug)
            .frame(height: Metrics.composerControlHeight)
            .background(Palette.surfaceRaised, in: .rect(cornerRadius: Radius.chip))
            .overlay { RoundedRectangle(cornerRadius: Radius.chip).strokeBorder(Palette.edge) }
        }
    }

    private var placeholder: String {
        switch kind {
        case .category: "New Category"
        case .forum: "forum-discussion"
        default: "new-channel"
        }
    }

    private var privacySwitch: some View {
        Toggle(isOn: $isPrivate) {
            HStack(alignment: .top, spacing: Spacing.snug) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Ink.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isCategory ? "Private Category" : "Private Channel")
                        .font(.system(.body, weight: .medium))
                        .foregroundStyle(Ink.primary)
                    Text(isCategory
                        ? "By making a category private, only select members and roles will be able to view this category. Linked channels in this category will automatically match to this setting."
                        : "Only selected members and roles will be able to view this channel.")
                        .font(.system(.caption))
                        .foregroundStyle(Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }

    private var categoryName: String? {
        guard !isCategory, let parentID = request.parentID else { return nil }
        return model.channelIndex[parentID]?.name
    }

    // MARK: Acts

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !isWorking else { return }
        isWorking = true
        failure = nil
        Task {
            let refusal = await model.sessionController.createChannel(
                name: trimmed,
                kind: kind,
                parentID: request.parentID,
                isPrivate: isPrivate,
                duplicating: request.duplicating,
                in: request.guildID
            )
            isWorking = false
            if let refusal {
                failure = refusal
            } else {
                dismiss()
            }
        }
    }
}

/// One choice in Channel Type: its mark, Discord's name and line for it, and
/// the radio — the whole row is the control.
private struct ChannelTypeOption: View {
    var kind: ChannelKind
    var isPrivate: Bool
    var isSelected: Bool
    var choose: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: choose) {
            HStack(spacing: Spacing.snug) {
                Image(symbol: kind.symbolName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Ink.secondary)
                    .frame(width: 24)
                    .overlay(alignment: .bottomTrailing) {
                        if isPrivate {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(Ink.secondary)
                                .offset(x: 2, y: 2)
                        }
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text(Self.title(kind))
                        .font(.system(.body, weight: .medium))
                        .foregroundStyle(Ink.primary)
                    Text(Self.line(kind))
                        .font(.system(.caption))
                        .foregroundStyle(Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Spacing.base)
                Image(symbol: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(isSelected ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(Ink.tertiary))
            }
            .padding(.horizontal, Spacing.snug)
            .padding(.vertical, Spacing.base)
            .background(
                isSelected ? Palette.selectionFill : (isHovering ? Palette.hoverFill : Color.clear),
                in: .rect(cornerRadius: Radius.chip)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// Discord's names (`pnuRXC`, `Sx55Oh`, `eAVID5`, `6x6fVg`, `qr9dEP`, `pNWst0`).
    static func title(_ kind: ChannelKind) -> String {
        switch kind {
        case .voice: "Voice"
        case .forum: "Forum"
        case .media: "Media"
        case .announcement: "Announcement"
        case .stage: "Stage"
        default: "Text"
        }
    }

    /// Discord's line under each.
    static func line(_ kind: ChannelKind) -> String {
        switch kind {
        case .voice: "Hang out together with voice, video, and screen share"
        case .forum: "Create a space for organized discussions"
        case .media: "Share videos, photos, and files with your members."
        case .announcement: "Important updates for people in and out of the server"
        case .stage: "Host events, panels, and Q&As for an audience"
        default: "Send messages, images, GIFs, emoji, opinions, and puns"
        }
    }
}
