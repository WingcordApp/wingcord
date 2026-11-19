import AppKit
import SwiftUI
import WingcordCore

/// What `.modal(item:)` holds while an application's form is up.
struct InteractionFormRequest: Identifiable, Hashable {
    var id: String
}

/// A form an application raised — Discord's interaction modal — on the
/// window's one form card (docs/BETA3.md §2.4).
///
/// **`FormSheet`, as every other form in the window** (Alex, 2026-11-18: "use
/// the sheet that we have already built"). It used to be a panel of its own
/// whose dropdowns were their whole option list laid open, so a select with
/// fourteen choices ran off the bottom of the screen. Now a dropdown is a
/// dropdown, a tall form scrolls inside its card, Cancel and Submit sit where
/// every other form puts them (Escape and Return, or ⌘Return beside a
/// paragraph), and the member, role and channel pickers and the file uploads
/// that Discord's forms carry have surfaces of their own.
struct InteractionFormSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let state = model.interactionModal {
            let modal = state.modal
            FormSheet(
                title: modal.title.isEmpty ? "Form" : modal.title,
                subtitle: modal.applicationName.map { Text("From \($0)") },
                confirmTitle: "Submit",
                isWorking: state.isSubmitting,
                canConfirm: !state.isSubmitting && modal.isComplete(state.answers),
                closesOnConfirm: false,
                confirmShortcut: modal.hasParagraph ? KeyboardShortcut(.return, modifiers: .command) : .defaultAction,
                width: 480,
                confirm: { model.sessionController.submitInteractionModal() }
            ) {
                let guildID = model.channelIndex.guildID(of: modal.channelID)
                ForEach(Array(modal.fields.enumerated()), id: \.offset) { _, field in
                    FormField(field: field, answers: state.answers, guildID: guildID, set: set)
                }
                if let failure = state.failure {
                    Label(failure, systemImage: "exclamationmark.circle")
                        .font(.system(.subheadline))
                        .foregroundStyle(Palette.destructive)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func set(_ customID: String, _ answer: InteractionModal.Answer) {
        model.interactionModal?.answers[customID] = answer
        model.interactionModal?.failure = nil
    }
}

// MARK: - One field

/// One field, drawn for what it is.
private struct FormField: View {
    var field: InteractionModal.Field
    var answers: [String: InteractionModal.Answer]
    var guildID: GuildID?
    var set: (String, InteractionModal.Answer) -> Void

    var body: some View {
        switch field {
        case .row(let children):
            VStack(alignment: .leading, spacing: Spacing.margin) {
                ForEach(Array(children.enumerated()), id: \.offset) { _, child in
                    FormField(field: child, answers: answers, guildID: guildID, set: set)
                }
            }
        case .label(let text, let description, let inner):
            VStack(alignment: .leading, spacing: Spacing.tight) {
                FormFieldHeader(title: text, detail: description, isRequired: inner.formIsRequired)
                FormField(field: inner, answers: answers, guildID: guildID, set: set)
            }
        case .text(let markdown):
            Text(Self.attributed(markdown))
                .font(.system(.subheadline))
                .foregroundStyle(Ink.primary)
                .fixedSize(horizontal: false, vertical: true)
        case .textInput(let input):
            VStack(alignment: .leading, spacing: Spacing.tight) {
                if let label = input.label, !label.isEmpty {
                    FormFieldHeader(title: label, detail: nil, isRequired: input.isRequired)
                }
                FormTextInput(input: input, text: text(input.customID)) { set(input.customID, .text($0)) }
            }
        case .select(let menu):
            FormDropdown(menu: menu, chosen: values(menu.customID)) { set(menu.customID, .values($0)) }
        case .radioGroup(let choice):
            FormOptionList(options: choice.options, chosen: values(choice.customID), isSingle: true, maxValues: 1) {
                set(choice.customID, .values($0))
            }
        case .checkboxGroup(let choice):
            FormOptionList(
                options: choice.options,
                chosen: values(choice.customID),
                isSingle: false,
                maxValues: choice.maxValues ?? choice.options.count
            ) { set(choice.customID, .values($0)) }
        case .checkbox(let customID, let isDefault):
            Toggle(isOn: Binding(
                get: {
                    if case .flag(let value) = answers[customID] { return value }
                    return isDefault
                },
                set: { set(customID, .flag($0)) }
            )) { EmptyView() }
            .toggleStyle(.checkbox)
            .labelsHidden()
        case .entitySelect(let select):
            EntityPicker(select: select, guildID: guildID, chosen: values(select.customID)) {
                set(select.customID, .values($0))
            }
        case .fileUpload(let upload):
            FileUploadField(upload: upload, files: InteractionModal.files(answers[upload.customID])) {
                set(upload.customID, .files($0))
            }
        case .unsupported:
            Text("This field can’t be filled in from Wingcord yet.")
                .font(.system(.caption))
                .foregroundStyle(Ink.tertiary)
        }
    }

    private func text(_ customID: String) -> String {
        if case .text(let text) = answers[customID] { return text }
        return ""
    }

    private func values(_ customID: String) -> [String] {
        InteractionModal.values(answers[customID])
    }

    static func attributed(_ markdown: String) -> AttributedString {
        (try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(markdown)
    }
}

/// A field's name, Discord's red mark on a required one, and the line under
/// it — above the control, where Discord puts it.
private struct FormFieldHeader: View {
    var title: String
    var detail: String?
    var isRequired: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 2) {
                Text(title)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                if isRequired {
                    Text("*")
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(Palette.destructive)
                        .accessibilityLabel(Text("Required"))
                }
            }
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(.caption))
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The well every control in the form sits in.
private struct FormWell: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(Spacing.base)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.chip, style: .continuous).fill(Palette.hoverFill))
    }
}

/// A text input: one line, or a paragraph, counted where the application set
/// a limit.
private struct FormTextInput: View {
    var input: InteractionModal.TextInput
    var text: String
    var write: (String) -> Void

    var body: some View {
        let binding = Binding(get: { text }, set: { value in
            write(input.maxLength.map { String(value.prefix($0)) } ?? value)
        })
        VStack(alignment: .trailing, spacing: Spacing.hair) {
            Group {
                if input.isParagraph {
                    TextEditor(text: binding)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 88, maxHeight: 220)
                        .overlay(alignment: .topLeading) {
                            if text.isEmpty, let placeholder = input.placeholder {
                                Text(placeholder)
                                    .foregroundStyle(Ink.tertiary)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }
                } else {
                    TextField(input.placeholder ?? "", text: binding)
                        .textFieldStyle(.plain)
                }
            }
            .font(.system(.body))
            .modifier(FormWell())
            if let maxLength = input.maxLength {
                Text("\(text.count)/\(maxLength)")
                    .font(.system(.caption2))
                    .foregroundStyle(Ink.tertiary)
                    .monospacedDigit()
            }
        }
    }
}

/// A closed field that opens a list: what a dropdown and a picker look like at
/// rest — the choice (or the placeholder) and the up-down chevron.
private struct FormMenuField: View {
    var summary: String
    var isEmpty: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.base) {
                Text(summary)
                    .foregroundStyle(isEmpty ? Ink.tertiary : Ink.primary)
                    .lineLimit(1)
                Spacer(minLength: Spacing.base)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(Ink.secondary)
            }
            .font(.system(.body))
            .modifier(FormWell())
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// A string select: Discord's dropdown, as a flyout of the chat's own option
/// rows (emoji, label, description). One choice closes it; several tick, and
/// stop at the maximum.
private struct FormDropdown: View {
    var menu: SelectMenu
    var chosen: [String]
    var write: ([String]) -> Void

    @State private var isOpen = false

    var body: some View {
        FormMenuField(summary: summary, isEmpty: chosen.isEmpty) { isOpen.toggle() }
            .popover(isPresented: $isOpen, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 0) {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(menu.options) { option in
                                SelectOptionRow(
                                    option: option,
                                    isChosen: chosen.contains(option.value),
                                    isSingle: menu.isSingle,
                                    isAvailable: menu.isSingle
                                        || chosen.contains(option.value)
                                        || chosen.count < menu.maxValues
                                ) { pick(option.value) }
                            }
                        }
                        .padding(.vertical, Spacing.tight)
                    }
                    .frame(maxHeight: 360)
                    .fixedSize(horizontal: false, vertical: true)
                    if !menu.isSingle {
                        FlyoutCaption(text: menu.maxValues >= menu.options.count
                            ? "Choose any."
                            : "Choose up to \(menu.maxValues).")
                            .padding(.vertical, Spacing.tight)
                    }
                }
                .frame(width: 320)
            }
            .accessibilityLabel(Text(menu.placeholder ?? "Choose"))
            .accessibilityValue(Text(summary))
    }

    private var summary: String {
        let labels = menu.options.filter { chosen.contains($0.value) }.map(\.label)
        return labels.isEmpty ? (menu.placeholder ?? "Make a selection") : labels.joined(separator: ", ")
    }

    private func pick(_ value: String) {
        if menu.isSingle {
            write([value])
            isOpen = false
        } else if chosen.contains(value) {
            write(chosen.filter { $0 != value })
        } else {
            // In the options' own order, which is the order the application wrote.
            let next = Set(chosen + [value])
            write(menu.options.map(\.value).filter(next.contains))
        }
    }
}

/// A radio group or a checkbox group: few choices, meant to be seen at once,
/// so laid open — Discord draws them the same way.
private struct FormOptionList: View {
    var options: [SelectMenu.Option]
    var chosen: [String]
    var isSingle: Bool
    var maxValues: Int
    var write: ([String]) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(options) { option in
                let isChosen = chosen.contains(option.value)
                SelectOptionRow(
                    option: option,
                    isChosen: isChosen,
                    isSingle: isSingle,
                    isAvailable: isSingle || isChosen || chosen.count < maxValues
                ) {
                    if isSingle {
                        write([option.value])
                    } else if isChosen {
                        write(chosen.filter { $0 != option.value })
                    } else {
                        let next = Set(chosen + [option.value])
                        write(options.map(\.value).filter(next.contains))
                    }
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: Radius.chip, style: .continuous).fill(Palette.hoverFill))
    }
}

// MARK: - Member, role and channel pickers

/// A member, role, mentionable or channel picker: the field, and a flyout
/// that searches what the server holds — faces for people, colours for roles,
/// marks for channels — with the application's preselection already ticked.
private struct EntityPicker: View {
    var select: InteractionModal.EntitySelect
    var guildID: GuildID?
    var chosen: [String]
    var write: ([String]) -> Void

    @Environment(AppModel.self) private var model
    @State private var isOpen = false
    @State private var query = ""

    struct Candidate: Identifiable, Hashable {
        var id: String
        var name: String
        var avatarURL: URL?
        var monogram: String?
        var colorValue: UInt32?
        var symbol: String?
    }

    var body: some View {
        FormMenuField(summary: summary, isEmpty: chosen.isEmpty) { isOpen.toggle() }
            .popover(isPresented: $isOpen, arrowEdge: .bottom) {
                VStack(spacing: 0) {
                    TextField(searchPrompt, text: $query)
                        .textFieldStyle(.roundedBorder)
                        .padding(Spacing.base)
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(matches) { candidate in
                                row(candidate)
                            }
                            if matches.isEmpty {
                                Text("Nothing matches.")
                                    .font(.system(.subheadline))
                                    .foregroundStyle(Ink.tertiary)
                                    .padding(Spacing.margin)
                            }
                        }
                        .padding(.vertical, Spacing.tight)
                    }
                    .frame(height: 280)
                    if !select.isSingle {
                        FlyoutCaption(text: "Choose up to \(select.maxValues).")
                            .padding(.bottom, Spacing.tight)
                    }
                }
                .frame(width: 320)
            }
            .accessibilityLabel(Text(select.placeholder ?? searchPrompt))
            .accessibilityValue(Text(summary))
    }

    private var searchPrompt: String {
        switch select.kind {
        case .user: "Search for people"
        case .role: "Search for roles"
        case .mentionable: "Search for people and roles"
        case .channel: "Search for channels"
        }
    }

    private var summary: String {
        let names = chosen.compactMap { id in candidates.first { $0.id == id }?.name }
        if names.isEmpty { return chosen.isEmpty ? (select.placeholder ?? "Make a selection") : "\(chosen.count) chosen" }
        return names.joined(separator: ", ")
    }

    private var matches: [Candidate] {
        let all = candidates
        let found = query.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(query) }
        return Array(found.prefix(200))
    }

    private var candidates: [Candidate] {
        var list: [Candidate] = []
        if select.kind == .user || select.kind == .mentionable { list += people }
        if select.kind == .role || select.kind == .mentionable { list += roles }
        if select.kind == .channel { list += channels }
        return list
    }

    /// The members this client holds for the server — or, outside one, the
    /// people it knows.
    private var people: [Candidate] {
        let ids: [UserID] = if let guildID {
            Array((model.members[guildID] ?? [:]).keys)
        } else {
            Array(model.users.keys.prefix(500))
        }
        return ids.compactMap { userID -> Candidate? in
            guard let user = model.users[userID] else { return nil }
            let name = guildID.flatMap { model.members[$0]?[userID]?.nickname } ?? user.preferredName
            return Candidate(
                id: String(userID.rawValue),
                name: name,
                avatarURL: model.avatarURL(forUserID: userID, inGuild: guildID, side: 20),
                monogram: user.monogram
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var roles: [Candidate] {
        guard let guildID else { return [] }
        return (model.roles[guildID] ?? [:]).values
            .filter { $0.id.rawValue != guildID.rawValue }
            .sorted { $0.position > $1.position }
            .map { Candidate(id: String($0.id.rawValue), name: $0.name, colorValue: $0.displayColorValue) }
    }

    private var channels: [Candidate] {
        guard let guildID else { return [] }
        return model.channelIndex.channelIDs(inGuild: guildID).compactMap { channelID -> Candidate? in
            guard let channel = model.channelIndex[channelID] else { return nil }
            let wanted = select.channelTypes.isEmpty
                ? channel.kind != .category
                : select.channelTypes.contains { ChannelKind(rawValue: $0) == channel.kind }
            guard wanted, model.permissionGate.canView(channelID) else { return nil }
            return Candidate(id: String(channelID.rawValue), name: channel.name, symbol: channel.kind.symbolName)
        }
    }

    private func row(_ candidate: Candidate) -> some View {
        let isChosen = chosen.contains(candidate.id)
        let isAvailable = select.isSingle || isChosen || chosen.count < select.maxValues
        return Button { pick(candidate.id) } label: {
            HStack(spacing: Spacing.base) {
                if let symbol = candidate.symbol {
                    Image(systemName: symbol)
                        .font(.system(.callout))
                        .foregroundStyle(Ink.secondary)
                        .frame(width: 20)
                } else if let monogram = candidate.monogram {
                    AvatarView(url: candidate.avatarURL, monogram: monogram, side: 20)
                } else {
                    Circle()
                        .fill(candidate.colorValue.map { Color(hex: $0) } ?? Ink.tertiary)
                        .frame(width: 10, height: 10)
                        .frame(width: 20)
                }
                Text(candidate.name)
                    .font(.system(.body))
                    .foregroundStyle(isAvailable ? Ink.primary : Ink.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isChosen {
                    Image(systemName: "checkmark")
                        .font(.system(.caption, weight: .bold))
                        .foregroundStyle(Palette.accent)
                }
            }
            .padding(.horizontal, Spacing.snug)
            .padding(.vertical, Spacing.tight)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }

    private func pick(_ id: String) {
        if select.isSingle {
            write([id])
            isOpen = false
        } else if chosen.contains(id) {
            write(chosen.filter { $0 != id })
        } else {
            write(chosen + [id])
        }
    }
}

// MARK: - File uploads

/// Files to send with the form: a drop zone that also opens Choose, the files
/// picked so far with their sizes, and a way to take one back. They go up when
/// the form is submitted (`SessionController.submitInteractionModal`).
private struct FileUploadField: View {
    var upload: InteractionModal.FileUpload
    var files: [InteractionModal.PickedFile]
    var write: ([InteractionModal.PickedFile]) -> Void

    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            ForEach(files) { file in
                HStack(spacing: Spacing.base) {
                    Image(systemName: "doc")
                        .foregroundStyle(Ink.secondary)
                    Text(file.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: Spacing.base)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
                        .font(.system(.caption))
                        .foregroundStyle(Ink.tertiary)
                    Button {
                        write(files.filter { $0.id != file.id })
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Ink.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Remove \(file.name)"))
                }
                .font(.system(.subheadline))
                .modifier(FormWell())
            }
            if files.count < upload.maxValues {
                Button(action: choose) {
                    VStack(spacing: Spacing.tight) {
                        Image(systemName: "arrow.up.doc")
                            .font(.system(.title3))
                            .foregroundStyle(isTargeted ? Palette.accent : Ink.secondary)
                        Text(upload.maxValues > 1 ? "Drop files here, or choose them" : "Drop a file here, or choose one")
                            .font(.system(.subheadline, weight: .medium))
                            .foregroundStyle(Ink.primary)
                        Text(upload.maxValues > 1 ? "Up to \(upload.maxValues) files" : "One file")
                            .font(.system(.caption))
                            .foregroundStyle(Ink.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Spacing.margin)
                    .background {
                        RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                            .strokeBorder(
                                isTargeted ? Palette.accent : Ink.tertiary,
                                style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
                            )
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .dropDestination(for: URL.self) { urls, _ in
                    add(urls)
                    return true
                } isTargeted: { isTargeted = $0 }
                .accessibilityLabel(Text(upload.maxValues > 1 ? "Choose files" : "Choose a file"))
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = upload.maxValues - files.count > 1
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    private func add(_ urls: [URL]) {
        var next = files
        for url in urls where url.isFileURL && next.count < upload.maxValues && !next.contains(where: { $0.url == url }) {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            next.append(InteractionModal.PickedFile(url: url, name: url.lastPathComponent, size: size))
        }
        write(next)
    }
}

// MARK: -

private extension InteractionModal {
    /// Whether a text area is in the form, which moves Submit to ⌘Return.
    var hasParagraph: Bool {
        inputs.contains { field in
            if case .textInput(let input) = field { return input.isParagraph }
            return false
        }
    }
}

private extension InteractionModal.Field {
    /// Whether the form cannot be sent without this — what the red mark says.
    var formIsRequired: Bool {
        switch self {
        case .textInput(let input): input.isRequired
        case .select(let menu): menu.minValues > 0
        case .radioGroup(let choice), .checkboxGroup(let choice): choice.isRequired
        case .entitySelect(let select): select.isRequired
        case .fileUpload(let upload): upload.isRequired
        case .row(let children): children.contains(where: \.formIsRequired)
        default: false
        }
    }
}
