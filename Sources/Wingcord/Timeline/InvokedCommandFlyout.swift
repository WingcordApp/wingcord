import SwiftUI
import WingcordCore

/// The one place a command's flyout is presented — at the window root, over the
/// chip on a "used" line that was pressed.
///
/// **A real `.popover`, as the expression card is** (`ExpressionInfoPresenter`):
/// the transcript is a drawn canvas and cannot host one, and the system's already
/// keeps itself on screen and closes on Escape and an outside click. Over the
/// chip, where Discord's popout opens (`position: "top", align: "center"`).
struct InvokedCommandPresenter: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var model = model
        content.popover(
            item: $model.invokedCommandRequest,
            attachmentAnchor: .rect(.rect(model.invokedCommandRequest?.anchor ?? .zero)),
            arrowEdge: .top
        ) { request in
            InvokedCommandHost(request: request)
                .presentationBackground(.clear)
        }
    }
}

extension View {
    /// Apply once, at the window root.
    func presentsInvokedCommand() -> some View {
        modifier(InvokedCommandPresenter())
    }
}

/// The line for one request, asked for once per opening.
private struct InvokedCommandHost: View {
    var request: InvokedCommandRequest

    @Environment(AppModel.self) private var model
    /// Until the route has answered, either way.
    @State private var isAsking = true

    var body: some View {
        Group {
            if let runs = model.commandLine(for: request) {
                InvokedCommandFlyout(
                    runs: runs,
                    isLoading: isAsking && model.invokedCommands[request.messageID] == nil,
                    openProfile: { userID in
                        model.invokedCommandRequest = nil
                        model.openProfile(userID, anchor: request.anchor)
                    }
                )
            }
        }
        // **Started here, not in the resolver**, which runs with every body.
        .task(id: request.id) {
            await model.sessionController.loadInvokedCommand(of: request.messageID, in: request.channelID)
            isAsking = false
        }
    }
}

/// A "used" line's command as it was run: `/8ball question: will it land?` —
/// Discord's popout (`Y` in `217424`), in the flyout's glass.
///
/// **Selectable**, as Discord's `user-select: text` is: the point of being shown
/// what somebody ran is often to run it yourself.
struct InvokedCommandFlyout: View {
    var runs: [CommandLineRun]
    /// Whether more of the line may still be coming.
    var isLoading = false
    var openProfile: (UserID) -> Void = { _ in }

    /// Discord's `max-width: 350px`, padding included; a long question wraps
    /// inside it.
    private static let maxWidth: CGFloat = 350
    /// `padding: 8px 12px`.
    private static let sidePadding = Spacing.base * 1.5
    /// The scheme a person's run is linked through. Never leaves this view.
    private static let personScheme = "wingcord-person"

    var body: some View {
        CappedWidth(max: Self.maxWidth - Self.sidePadding * 2) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.base) {
                Text(line)
                    .font(.system(.body))
                    .tint(Palette.accent)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .environment(\.openURL, OpenURLAction { url in
                        guard url.scheme == Self.personScheme,
                              let id = url.host().flatMap(UInt64.init)
                        else { return .discarded }
                        openProfile(UserID(rawValue: id))
                        return .handled
                    })
                if isLoading {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .padding(.horizontal, Self.sidePadding)
        .padding(.vertical, Spacing.base)
    }

    /// One attributed line, so it wraps as a sentence and selects as one.
    ///
    /// **The hierarchy is ink and weight, not paleness**: what was run and what
    /// it was given are full strength, and only the option's name steps back.
    private var line: AttributedString {
        var line = AttributedString()
        for run in runs {
            var piece = AttributedString(run.text)
            switch run.kind {
            case .command:
                piece.foregroundColor = Ink.primary
            case .label:
                piece.foregroundColor = Ink.secondary
            case .value:
                piece.foregroundColor = Ink.primary
                piece.font = .system(.body, weight: .medium)
            case .mention(let userID):
                piece.foregroundColor = Palette.accent
                piece.font = .system(.body, weight: .medium)
                if let userID {
                    piece.link = URL(string: "\(Self.personScheme)://\(userID.rawValue)")
                }
            }
            line.append(piece)
        }
        return line
    }
}
