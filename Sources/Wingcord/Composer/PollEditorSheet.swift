import SwiftUI
import WingcordCore

/// Discord's "Create a Poll" (module `143657`), for one conversation.
///
/// **A sheet**, for `ForwardSheet`'s reason: a question, up to ten answers, a
/// duration and a switch is a form with a Post at the end, not a menu.
///
/// **The rules are `PollDraft`'s** — Discord's limits and its three refusals —
/// so this view only draws them: each error sits under its field, and Post
/// checks once and puts the caret on the first field that is wrong.
///
/// **Post sends and closes**, as any send does: the poll is drawn in the
/// transcript at once and turns red with Resend if Discord refuses it. Schedule
/// Poll draws nothing, so the sheet waits for Discord instead and shows a
/// refusal here, where the poll still is.
struct PollEditorSheet: View {
    var request: PollEditorRequest

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var draft = PollDraft()
    @State private var problems: [PollDraft.Problem] = []
    @State private var refusal: String?
    @State private var isSubmitting = false
    @State private var isConfirmingExit = false
    @State private var isChoosingDuration = false
    @State private var isScheduling = false
    @FocusState private var focus: Field?

    private enum Field: Hashable {
        case question
        case answer(PollDraft.Answer.ID)
    }

    private static let width: CGFloat = 480
    private static let formHeight: CGFloat = 440

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ModalHeader(title: "Create a Poll", close: requestClose)
            ScrollView {
                form
            }
            .frame(maxHeight: Self.formHeight)
            .scrollBounceBehavior(.basedOnSize)
            .softScrollEdgesVertical()
            footer
        }
        .frame(width: Self.width)
        // Thrown away, a poll with words in it would lose them: the ✕ asks.
        .modalDismissDisabled(!draft.isUntouched)
        .animation(motion.standard, value: draft.answers.map(\.id))
        .animation(motion.standard, value: problems)
        .onAppear { focus = .question }
        // Discord keeps each field to its limit as it is typed, and an edit
        // takes that field's error away.
        .onChange(of: draft.question) { _, question in
            if question.count > PollDraft.questionLimit {
                draft.question = String(question.prefix(PollDraft.questionLimit))
            }
            problems.removeAll { $0 == .noQuestion }
        }
        .onChange(of: draft.answers.map(\.text)) {
            for index in draft.answers.indices where draft.answers[index].text.count > PollDraft.answerLimit {
                draft.answers[index].text = String(draft.answers[index].text.prefix(PollDraft.answerLimit))
            }
            problems.removeAll { $0 != .noQuestion }
        }
        // Discord's words; red, because losing the poll is the result nobody
        // chose (D11b).
        .modal(isPresented: $isConfirmingExit, style: .alert) {
            ModalAlert(
                hero: .symbol("exclamationmark.triangle.fill", tint: .orange),
                title: "Are you sure?",
                message: Text("Are you sure you want to exit? Any changes made will be lost if you exit now."),
                actions: [
                    .cancel("Back to editing"),
                    .destructive("Exit", symbol: "xmark.circle") { close() },
                ]
            )
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: Spacing.margin) {
            if let refusal {
                Label(refusal, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(.subheadline))
                    .foregroundStyle(Palette.destructive)
                    .transition(.opacity)
            }
            section("Question") {
                question
            }
            section("Answers") {
                ForEach($draft.answers) { $answer in
                    let number = (draft.answers.firstIndex { $0.id == answer.id } ?? 0) + 1
                    answerRow($answer, number: number)
                    // Discord pins "add at least one answer" to the first row.
                    if number == 1, problems.contains(.noAnswers) {
                        problemLine(.noAnswers)
                    }
                    if problems.contains(.answerWithoutWords(answer.id)) {
                        problemLine(.answerWithoutWords(answer.id))
                    }
                }
                if draft.canAddAnswer {
                    Button(action: addAnswer) {
                        Label("Add another answer", systemImage: "plus")
                            .font(.system(.subheadline, weight: .medium))
                            .padding(.horizontal, Spacing.snug)
                            .frame(height: Metrics.composerControlHeight)
                            .background(Palette.surfaceRaised, in: .capsule)
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Ink.primary)
                    .overlay { Capsule().strokeBorder(Palette.edge) }
                }
            }
            section("Duration") {
                durationPicker
            }
        }
        .padding(.horizontal, Spacing.group)
        .padding(.bottom, Spacing.margin)
    }

    private var footer: some View {
        HStack(spacing: Spacing.snug) {
            Toggle("Allow Multiple Answers", isOn: $draft.allowsMultiselect)
                .toggleStyle(.checkbox)
                .font(.system(.subheadline))
                .foregroundStyle(Ink.primary)
            Spacer(minLength: Spacing.base)
            if model.canScheduleMessages(in: request.channelID) {
                scheduleControl
            }
            // Discord's ⌘↩ from anywhere in the form.
            ModalButton(
                title: "Post",
                symbolName: "paperplane.fill",
                role: .act,
                isWorking: isSubmitting,
                shortcut: KeyboardShortcut(.return, modifiers: .command),
                action: submit
            )
        }
        .padding(.horizontal, Spacing.group)
        .padding(.vertical, Spacing.margin)
    }

    // MARK: Fields

    private var question: some View {
        VStack(alignment: .trailing, spacing: Spacing.tight) {
            TextField("What question do you want to ask?", text: $draft.question, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(.body))
                .lineLimit(1...4)
                .focused($focus, equals: .question)
                .padding(.horizontal, Spacing.snug)
                .padding(.vertical, Spacing.base)
                .background(Palette.surfaceRaised, in: .rect(cornerRadius: Radius.chip))
                .overlay { RoundedRectangle(cornerRadius: Radius.chip).strokeBorder(Palette.edge) }
            Text("\(draft.question.count)/\(PollDraft.questionLimit)")
                .font(.system(.caption2).monospacedDigit())
                .foregroundStyle(Ink.tertiary)
            if problems.contains(.noQuestion) {
                problemLine(.noQuestion)
            }
        }
    }

    private func answerRow(_ answer: Binding<PollDraft.Answer>, number: Int) -> some View {
        let id = answer.wrappedValue.id
        return HStack(spacing: Spacing.base) {
            EmojiSlotButton(
                emoji: answer.emoji,
                addLabel: "Add emoji, answer \(number)",
                updateLabel: { "Update emoji, \($0.name), answer \(number)" },
                // An answer names its emoji, as a reaction does.
                destination: .channel(request.channelID)
            )
            TextField("Type your answer", text: answer.text)
                .textFieldStyle(.plain)
                .font(.system(.body))
                .focused($focus, equals: .answer(id))
                // Return on the last answer adds another, as Discord's does.
                .onSubmit {
                    if id == draft.answers.last?.id { addAnswer() }
                }
                .accessibilityLabel(Text("Answer \(number)"))
            if draft.canRemoveAnswer {
                Button { remove(id) } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 28, height: 28)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Ink.secondary)
                .help("Remove answer \(number)")
                .accessibilityLabel(Text("Remove answer \(number)"))
            }
        }
        .padding(.leading, Spacing.tight)
        .padding(.trailing, Spacing.base)
        .frame(minHeight: Metrics.composerControlHeight)
        .background(Palette.surfaceRaised, in: .capsule)
        .overlay { Capsule().strokeBorder(Palette.edge) }
    }

    /// Discord's dropdown, as this app draws a choice: a flyout with a tick.
    private var durationPicker: some View {
        Button { isChoosingDuration = true } label: {
            HStack(spacing: Spacing.base) {
                Text(draft.duration.title)
                    .font(.system(.body))
                Spacer(minLength: Spacing.base)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Ink.tertiary)
            }
            .padding(.horizontal, Spacing.snug)
            .frame(height: Metrics.composerControlHeight)
            .background(Palette.surfaceRaised, in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Ink.primary)
        .overlay { Capsule().strokeBorder(Palette.edge) }
        .accessibilityLabel(Text("Poll will be live for \(draft.duration.title)"))
        .popover(isPresented: $isChoosingDuration, arrowEdge: .bottom) {
            VStack(spacing: 0) {
                ForEach(PollDraft.Duration.allCases) { duration in
                    FlyoutRow(title: duration.title, accessory: .tick(duration == draft.duration)) {
                        draft.duration = duration
                        isChoosingDuration = false
                    }
                }
            }
            .padding(.vertical, Spacing.tight)
            .frame(width: 200)
        }
    }

    /// The clock beside Post: Discord's Schedule Poll, lit while a time is set.
    private var scheduleControl: some View {
        Button { isScheduling = true } label: {
            Image(symbol: draft.scheduledAt == nil ? "clock" : "clock.fill")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: Metrics.composerControlHeight, height: Metrics.composerControlHeight)
                .background(
                    draft.scheduledAt == nil ? AnyShapeStyle(Palette.surfaceRaised) : AnyShapeStyle(Palette.accent.opacity(0.18)),
                    in: .circle
                )
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .foregroundStyle(draft.scheduledAt == nil ? AnyShapeStyle(Ink.primary) : AnyShapeStyle(Palette.accent))
        .overlay { Capsule().strokeBorder(Palette.edge) }
        .help(scheduleLabel)
        .accessibilityLabel(Text(scheduleLabel))
        .popover(isPresented: $isScheduling, arrowEdge: .top) {
            ScheduleTimeForm(
                initial: draft.scheduledAt ?? ScheduleWindow.suggestedTime(at: .now),
                clear: draft.scheduledAt == nil ? nil : {
                    draft.scheduledAt = nil
                    isScheduling = false
                },
                cancel: { isScheduling = false },
                set: { date in
                    draft.scheduledAt = date
                    isScheduling = false
                }
            )
            .frame(width: ComposerAttachMenu.width)
        }
    }

    private var scheduleLabel: String {
        guard let date = draft.scheduledAt else { return "Schedule Poll" }
        return "Scheduling for \(date.formatted(.dateTime.month(.wide).day())) at \(date.formatted(date: .omitted, time: .shortened))"
    }

    // MARK: Pieces

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            Text(title)
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(Ink.tertiary)
                .textCase(.uppercase)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func problemLine(_ problem: PollDraft.Problem) -> some View {
        Text(problem.message)
            .font(.system(.caption))
            .foregroundStyle(Palette.destructive)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Acts

    private func addAnswer() {
        guard draft.canAddAnswer else { return }
        let answer = PollDraft.Answer()
        draft.answers.append(answer)
        focus = .answer(answer.id)
    }

    private func remove(_ id: PollDraft.Answer.ID) {
        guard draft.canRemoveAnswer else { return }
        draft.answers.removeAll { $0.id == id }
    }

    private func submit() {
        guard !isSubmitting else { return }
        problems = draft.problems
        if let first = problems.first {
            switch first {
            case .noQuestion: focus = .question
            case .noAnswers: focus = draft.answers.first.map { .answer($0.id) }
            case .answerWithoutWords(let id): focus = .answer(id)
            }
            return
        }
        guard let date = draft.scheduledAt else {
            model.postPoll(draft, in: request.channelID)
            close()
            return
        }
        isSubmitting = true
        refusal = nil
        Task {
            let refused = await model.schedulePoll(draft, at: date, in: request.channelID)
            isSubmitting = false
            if let refused {
                refusal = refused
            } else {
                close()
            }
        }
    }

    private func requestClose() {
        if draft.isUntouched { close() } else { isConfirmingExit = true }
    }

    private func close() {
        model.pollEditor = nil
    }
}

