import SwiftUI
import WingcordCore

/// A form an application raised — Discord's interaction modal, as a layer
/// over the window.
///
/// **The reactors list's recipe**: clear glass over the modal scrim, in the
/// window rather than a sheet, so it stacks with the app's other layers and
/// Escape — or a click outside, as in Discord — cancels it (`EscapeLayer`).
struct InteractionModalLayer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion

    var body: some View {
        let state = model.interactionModal
        ZStack {
            if let state {
                Button { model.interactionModal = nil } label: {
                    Palette.modalScrim.contentShape(.rect)
                }
                .buttonStyle(.plain)
                .cancelAction(unless: model.isCovered(.interactionModal))
                .accessibilityLabel(Text("Cancel"))
                .ignoresSafeArea()
                .transition(.opacity)

                InteractionModalPanel(state: state)
                    .id(state.modal.id)
                    .frame(maxWidth: 440, maxHeight: 640)
                    .padding(32)
                    .transition(.materialize)
            }
        }
        .animation(motion.panel, value: state?.modal.id)
    }
}

/// The form: who is asking, what they call it, the fields, and Cancel and
/// Submit.
private struct InteractionModalPanel: View {
    var state: InteractionModalState

    @Environment(AppModel.self) private var model

    private var modal: InteractionModal { state.modal }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Palette.selectionFill).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.margin) {
                    ForEach(Array(modal.fields.enumerated()), id: \.offset) { _, field in
                        ModalFieldView(field: field, answers: state.answers, set: set)
                    }
                }
                .padding(Spacing.margin)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .fixedSize(horizontal: false, vertical: true)
            Rectangle().fill(Palette.selectionFill).frame(height: 1)
            footer
        }
        .modalPanel(in: RoundedRectangle(cornerRadius: Radius.card))
    }

    private func set(_ customID: String, _ answer: InteractionModal.Answer) {
        model.interactionModal?.answers[customID] = answer
        model.interactionModal?.failure = nil
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Spacing.snug) {
            VStack(alignment: .leading, spacing: Spacing.tight) {
                HStack(spacing: Spacing.tight) {
                    if let hash = modal.applicationIconHash {
                        RemoteImage(url: CDN.applicationIcon(id: modal.applicationID, hash: hash, side: 16), side: 16) {
                            Color.clear
                        }
                        .frame(width: 16, height: 16)
                        .clipShape(.rect(cornerRadius: 4, style: .continuous))
                    }
                    if let name = modal.applicationName {
                        Text(name)
                            .font(.system(.caption, weight: .semibold))
                            .foregroundStyle(InkColor.secondary)
                    }
                }
                Text(modal.title)
                    .font(.system(.headline))
                    .foregroundStyle(InkColor.primary)
            }
            Spacer(minLength: 0)
            Button { model.interactionModal = nil } label: {
                Image(systemName: "xmark")
                    .font(.system(.body, weight: .semibold))
                    .foregroundStyle(InkColor.solid)
                    .frame(width: Metrics.control, height: Metrics.control)
                    // A region inside the panel's material — glass on glass
                    // is §4's first rule.
                    .background(Circle().fill(Palette.hoverFill))
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .help("Cancel")
            .accessibilityLabel(Text("Cancel"))
        }
        .padding(Spacing.margin)
    }

    private var footer: some View {
        HStack(spacing: Spacing.snug) {
            if let failure = state.failure {
                Text(failure)
                    .font(.system(.caption))
                    .foregroundStyle(Palette.destructive)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("Cancel") { model.interactionModal = nil }
                .buttonStyle(.bordered)
            Button {
                model.sessionController.submitInteractionModal()
            } label: {
                if state.isSubmitting {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Submit")
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(state.isSubmitting || !modal.isComplete(state.answers))
        }
        .padding(Spacing.margin)
    }
}

/// One field, drawn for what it is.
private struct ModalFieldView: View {
    var field: InteractionModal.Field
    var answers: [String: InteractionModal.Answer]
    var set: (String, InteractionModal.Answer) -> Void

    var body: some View {
        switch field {
        case .row(let children):
            VStack(alignment: .leading, spacing: Spacing.margin) {
                ForEach(Array(children.enumerated()), id: \.offset) { _, child in
                    ModalFieldView(field: child, answers: answers, set: set)
                }
            }
        case .label(let text, let description, let inner):
            VStack(alignment: .leading, spacing: Spacing.tight) {
                ModalFieldLabel(text: text, isRequired: inner.isRequired)
                if let description, !description.isEmpty {
                    Text(description)
                        .font(.system(.caption))
                        .foregroundStyle(InkColor.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ModalFieldView(field: inner, answers: answers, set: set)
            }
        case .text(let markdown):
            Text((try? AttributedString(
                markdown: markdown,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )) ?? AttributedString(markdown))
                .font(.system(.subheadline))
                .foregroundStyle(InkColor.primary)
                .fixedSize(horizontal: false, vertical: true)
        case .textInput(let input):
            VStack(alignment: .leading, spacing: Spacing.tight) {
                if let label = input.label, !label.isEmpty {
                    ModalFieldLabel(text: label, isRequired: input.isRequired)
                }
                ModalTextInput(input: input, text: text(input.customID)) { set(input.customID, .text($0)) }
            }
        case .select(let menu):
            options(menu.options, customID: menu.customID, isSingle: menu.isSingle, maxValues: menu.maxValues)
        case .radioGroup(let choice):
            options(choice.options, customID: choice.customID, isSingle: true, maxValues: 1)
        case .checkboxGroup(let choice):
            options(
                choice.options, customID: choice.customID, isSingle: false,
                maxValues: choice.maxValues ?? choice.options.count
            )
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
        case .unsupported:
            Text("This field can’t be filled in from Wingcord yet.")
                .font(.system(.caption))
                .foregroundStyle(InkColor.tertiary)
        }
    }

    private func text(_ customID: String) -> String {
        if case .text(let text) = answers[customID] { return text }
        return ""
    }

    /// A select, a radio group or a checkbox group, laid open: the form has
    /// the room a menu's flyout does not, so the options are simply listed.
    private func options(
        _ options: [SelectMenu.Option],
        customID: String,
        isSingle: Bool,
        maxValues: Int
    ) -> some View {
        let chosen = InteractionModal.values(answers[customID])
        return VStack(spacing: 0) {
            ForEach(options) { option in
                let isChosen = chosen.contains(option.value)
                SelectOptionRow(
                    option: option,
                    isChosen: isChosen,
                    isSingle: isSingle,
                    isAvailable: isSingle || isChosen || chosen.count < maxValues
                ) {
                    if isSingle {
                        set(customID, .values([option.value]))
                    } else if isChosen {
                        set(customID, .values(chosen.filter { $0 != option.value }))
                    } else {
                        // In the options' own order, which is the order the
                        // application wrote.
                        let next = Set(chosen + [option.value])
                        set(customID, .values(options.map(\.value).filter(next.contains)))
                    }
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: Radius.chip, style: .continuous).fill(Palette.hoverFill))
    }
}

/// A field's name, with Discord's red mark on a required one.
private struct ModalFieldLabel: View {
    var text: String
    var isRequired: Bool

    var body: some View {
        HStack(spacing: 2) {
            Text(text)
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(InkColor.primary)
            if isRequired {
                Text("*").font(.system(.subheadline, weight: .semibold)).foregroundStyle(Palette.destructive)
            }
        }
    }
}

/// A text input: one line, or a paragraph, with its length counted where the
/// application set a limit.
private struct ModalTextInput: View {
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
                        .frame(minHeight: 88)
                        .overlay(alignment: .topLeading) {
                            if text.isEmpty, let placeholder = input.placeholder {
                                Text(placeholder)
                                    .foregroundStyle(InkColor.tertiary)
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
            .padding(Spacing.base)
            .background(RoundedRectangle(cornerRadius: Radius.chip, style: .continuous).fill(Palette.hoverFill))
            if let maxLength = input.maxLength {
                Text("\(text.count)/\(maxLength)")
                    .font(.system(.caption2))
                    .foregroundStyle(InkColor.tertiary)
                    .monospacedDigit()
            }
        }
    }
}

private extension InteractionModal.Field {
    /// Whether the form cannot be sent without this — what the red mark says.
    var isRequired: Bool {
        switch self {
        case .textInput(let input): input.isRequired
        case .select(let menu): menu.minValues > 0
        case .radioGroup(let choice), .checkboxGroup(let choice): choice.isRequired
        case .row(let children): children.contains(where: \.isRequired)
        default: false
        }
    }
}
