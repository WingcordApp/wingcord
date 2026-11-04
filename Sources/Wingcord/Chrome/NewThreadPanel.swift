import AppKit
import SwiftUI
import WingcordCore

/// Discord's New Thread (`sF`), in the column a thread opens in: the thread's
/// name, whether it is private, the message it hangs off, and its first
/// message — which is what starts it.
///
/// **Discord's words and Discord's checks**: "Thread Name", or "Thread Name
/// (Optional)" off a message, where Discord names it from the message; "Private
/// Thread" with "Only people you invite and moderators can see", fixed on where
/// the reader may only start private threads; "Enter a message to start the
/// conversation!"; and "Thread Name is required" / "Starter Message is
/// required" under the field at fault.
///
/// **Nothing typed is lost by stepping away.** The channel's composer handed
/// its words over when this opened, and they go back if the panel goes away
/// unsent — see `AppModel.abandonNewThread`. Close is the exception, as in
/// Discord (`sw`): with a name or a message it asks "Are you sure you want to
/// go?", and Exit throws them away — Discord's `bA` clears the thread's draft.
struct NewThreadPanel: View {
    var request: NewThreadRequest

    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var isPrivate = false
    @State private var text = ""
    @State private var isTextFocused = true
    @State private var refusal: NewThreadRefusal?
    @State private var isSubmitting = false
    @State private var isConfirmingExit = false
    /// Exit was chosen: the words leave with the panel.
    @State private var isDiscarded = false

    /// Discord's cap on a channel's name.
    private static let nameLimit = 100

    var body: some View {
        let form = model.newThreadForm(for: request)
        VStack(spacing: 0) {
            header(isPrivate: makesPrivate(form))
            ScrollView {
                if let form { fields(form) }
            }
            .scrollBounceBehavior(.basedOnSize)
            foot
        }
        .frame(width: Proportions.threadColumnIdeal)
        // The column's own edge, as the thread panel draws it.
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Ink.quaternary)
                .frame(width: 1)
                .ignoresSafeArea()
        }
        .onAppear {
            text = request.seedText
            if form?.privateMode == .privateOnly { isPrivate = true }
        }
        .onDisappear {
            // A thread that was made took its words with it; an exit threw
            // them away.
            guard !isSubmitting else { return }
            model.abandonNewThread(request, unsentText: isDiscarded ? "" : text)
        }
        // Red: losing the words is the result nobody chose (D11b).
        .modal(isPresented: $isConfirmingExit, style: .alert) {
            ModalAlert(
                hero: .symbol("exclamationmark.triangle.fill", tint: .orange),
                title: "Are you sure you want to go?",
                message: Text("Any changes you made will be lost if you exit now."),
                actions: [
                    .cancel("Back to editing"),
                    .destructive("Exit", symbol: "xmark.circle") {
                        isDiscarded = true
                        model.closeNewThread()
                    },
                ]
            )
        }
    }

    /// Discord's rule: a name or a message is something to lose.
    private func close() {
        if !name.isEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            isConfirmingExit = true
        } else {
            model.closeNewThread()
        }
    }

    private func makesPrivate(_ form: NewThreadForm?) -> Bool {
        switch form?.privateMode {
        case .privateOnly: true
        case .enabled: isPrivate
        case .disabled, nil: false
        }
    }

    /// "New Thread" with the thread glyph, and Close — the column's header.
    private func header(isPrivate: Bool) -> some View {
        GlassEffectContainer(spacing: Spacing.base) {
            HStack(spacing: Spacing.base) {
                ColumnHeaderIdentity(name: "New Thread", help: "New Thread") {
                    Image(symbol: isPrivate ? ChannelKind.privateThread.symbolName : DiscordGlyph.thread)
                }
                Spacer(minLength: 0)
                ColumnHeaderControl(systemImage: "xmark", label: "Close", action: close)
            }
        }
        .padding(.horizontal, Spacing.snug)
        .padding(.vertical, Spacing.base)
    }

    private func fields(_ form: NewThreadForm) -> some View {
        VStack(alignment: .leading, spacing: Spacing.margin) {
            // The thread's tile, as its head will draw it — the lock on a
            // private one.
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Palette.surfaceRaised)
                .frame(width: 64, height: 64)
                .overlay {
                    Image(symbol: makesPrivate(form) ? ChannelKind.privateThread.symbolName : DiscordGlyph.thread)
                        .font(.system(size: 28))
                        .foregroundStyle(Ink.secondary)
                }
                .accessibilityHidden(true)

            SheetField(title: form.isFromMessage ? "Thread Name (Optional)" : "Thread Name") {
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    TextField(form.namePlaceholder, text: Binding(
                        get: { name },
                        set: { name = String($0.prefix(Self.nameLimit)) }
                    ))
                    .modalField()
                    .onSubmit(submit)
                    .accessibilityLabel(Text(form.isFromMessage ? "Thread Name (Optional)" : "Thread Name"))
                    if let error = refusal?.nameError {
                        errorLine(error)
                    }
                }
            }

            if form.privateMode != .disabled {
                SheetField(
                    title: "Private Thread",
                    detail: makesPrivate(form) ? "You can invite new people by @mentioning them." : nil
                ) {
                    Toggle(
                        "Only people you invite and moderators can see",
                        isOn: Binding(get: { makesPrivate(form) }, set: { isPrivate = $0 })
                    )
                    .toggleStyle(.checkbox)
                    .disabled(form.privateMode == .privateOnly)
                }
            }

            // The message it hangs off, as Discord shows it above the first
            // message of the thread it is starting.
            if let author = form.messageAuthor, let words = form.messageText {
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    Text(author)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(Ink.primary)
                    Text(words)
                        .font(.system(.subheadline))
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(6)
                }
                .padding(Spacing.snug)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.hoverFill, in: .rect(cornerRadius: Radius.row, style: .continuous))
            }
        }
        .padding(Spacing.margin)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The thread's first message — what starts it. Return sends, as the
    /// composer's does.
    private var foot: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            if let error = refusal?.messageError {
                errorLine(error)
                    .padding(.horizontal, Spacing.snug)
            }
            MarkdownEditor(
                text: $text,
                isFocused: $isTextFocused,
                placeholder: "Enter a message to start the conversation!",
                font: NSFont.preferredFont(forTextStyle: .body),
                lines: 1...8,
                returnSubmits: true,
                onSubmit: submit
            )
            .padding(Spacing.base)
            .glassEffect(.regular, in: .rect(cornerRadius: Radius.glass))
            .disabled(isSubmitting)
        }
        .padding(.horizontal, Spacing.snug)
        .padding(.bottom, Spacing.snug)
    }

    private func errorLine(_ words: String) -> some View {
        Text(words)
            .font(.system(.caption))
            .foregroundStyle(Palette.destructive)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func submit() {
        guard !isSubmitting else { return }
        isSubmitting = true
        refusal = nil
        Task {
            let answer = await model.submitNewThread(request, name: name, isPrivate: isPrivate, text: text)
            // On success the panel is already gone, with its words.
            guard let answer else { return }
            refusal = answer
            isSubmitting = false
        }
    }
}
