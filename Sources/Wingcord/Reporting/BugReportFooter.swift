import SwiftUI

/// The card's capsules: the way out leading, the act trailing.
///
/// **Close on the form, Back on a page under it** — the HIG's Back is "for
/// the previous step, not for dismissing", and Escape follows it, so Escape
/// walks back one page and then closes. **The act is Send**, on ⌘Return
/// (Return belongs to the text areas); a bug keeps **Save Report…** beside it
/// for when there is no connection or the service turns it away — with the
/// ellipsis, since it opens the save panel.
struct BugReportFooter: View {
    var step: BugReporter.Step
    var kind: ReportKind
    var canSend: Bool
    var isSending: Bool
    var isSaving: Bool
    var historyIsStandalone: Bool
    var close: () -> Void
    var back: () -> Void
    var save: () -> Void
    var send: () -> Void
    var done: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: Spacing.snug) {
            HStack(spacing: Spacing.snug) {
                wayOut
                Spacer(minLength: 0)
                acts
            }
        }
        .padding(.horizontal, Spacing.margin)
        .padding(.top, Spacing.base)
        .padding(.bottom, Spacing.margin)
    }

    @ViewBuilder
    private var wayOut: some View {
        switch step {
        case .form:
            ModalButton(title: "Close", symbolName: "xmark", role: .cancel, action: close)
        case .contents:
            ModalButton(title: "Back", symbolName: "chevron.left", role: .cancel, action: back)
        case .history:
            if historyIsStandalone {
                ModalButton(title: "Close", symbolName: "xmark", role: .cancel, action: close)
            } else {
                ModalButton(title: "Back", symbolName: "chevron.left", role: .cancel, action: back)
            }
        case .sent:
            EmptyView()
        }
    }

    @ViewBuilder
    private var acts: some View {
        switch step {
        case .form, .contents:
            if kind == .bug {
                ModalButton(
                    title: "Save Report…",
                    symbolName: "square.and.arrow.down",
                    role: .secondary,
                    isWorking: isSaving,
                    action: save
                )
                .disabled(!canSend || isSending)
                .help(canSend ? "Save the report as a file you can send another way" : "Say what happened first")
            }
            ModalButton(
                title: kind == .bug ? "Send Report" : "Send Idea",
                symbolName: "paperplane",
                role: .act,
                isWorking: isSending,
                shortcut: KeyboardShortcut(.return, modifiers: .command),
                action: send
            )
            .disabled(!canSend || isSaving)
            .help(canSend ? "Send it to the developer (⌘Return)" : kind == .bug ? "Say what happened first" : "Say what you'd like first")
        case .sent:
            ModalButton(title: "Done", symbolName: "checkmark", role: .act, action: done)
        case .history:
            EmptyView()
        }
    }
}
