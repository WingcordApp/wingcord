import SwiftUI
import WingcordCore

/// An application's own page — Discord's `995198`, which a pending
/// application's tile opens: where it stands, in one card over the server's
/// splash, and what can be done about it.
///
/// Three cards, as Discord has three: awaiting review, denied, and not yet
/// sent. **Every word is Discord's**, including the server-less fallbacks it
/// shows before the server list has answered.
struct JoinRequestStatusPane: View, Equatable {
    var presentation: JoinRequestStatusPresentation

    static func == (lhs: JoinRequestStatusPane, rhs: JoinRequestStatusPane) -> Bool {
        lhs.presentation == rhs.presentation
    }

    /// Takes the application back without asking — a denial nobody can
    /// reapply to has nothing left to lose, and Discord does not ask.
    var withdraw: () -> Void = {}
    /// Asks first. `isDiscard` picks Discord's question.
    var askToWithdraw: (_ isDiscard: Bool) -> Void = { _ in }
    var reapply: () -> Void = {}
    var openApplication: () -> Void = {}

    /// Discord's card is at most 400 wide (`confirmation__1051d`).
    private static let cardWidth: CGFloat = 400

    var body: some View {
        card
            .frame(maxWidth: Self.cardWidth)
            .padding(Spacing.section)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { cover }
    }

    // MARK: The picture

    /// The server's splash, filling the page — the gate's own cover, for the
    /// gate's reasons: `.fill` with a clip, and a scrim the card can be read
    /// over whatever the artwork is. A server with no splash draws the raised
    /// surface, as Discord draws its plain gradient.
    private var cover: some View {
        Rectangle()
            .fill(Palette.surfaceRaised)
            .overlay {
                if let splashURL = presentation.splashURL {
                    RemoteImage(url: splashURL, side: 1600, bucket: .artwork) { Color.clear }
                        .aspectRatio(contentMode: .fill)
                }
            }
            .overlay {
                LinearGradient(
                    stops: [
                        .init(color: Palette.canvas.opacity(0.35), location: 0),
                        .init(color: Palette.canvas.opacity(0.62), location: 0.55),
                        .init(color: Palette.canvas.opacity(0.80), location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .clipped()
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }

    // MARK: The card

    private var card: some View {
        VStack(spacing: Spacing.group) {
            Image(symbol: symbolName)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Ink.primary)
                .frame(width: 48, height: 48)
                .background(Palette.canvas, in: .circle)
                .accessibilityHidden(true)

            VStack(spacing: Spacing.base) {
                Text(verbatim: headline)
                    .font(.system(.title3, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                    .accessibilityAddTraits(.isHeader)
                detail
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            actions
        }
        .frame(maxWidth: .infinity)
        .padding(Spacing.group)
        // **Clear glass over the server's artwork** — the gate's card, and §4's
        // rule for media: the tint goes in the material, never as a fill under
        // it.
        .chromeOverMedia(
            tinted: Palette.flyoutTint,
            in: .rect(cornerRadius: 16, style: .continuous)
        )
    }

    /// Discord's three glyphs: the hourglass of the folder, the cross of a
    /// denial, and a list for a form still to fill.
    private var symbolName: String {
        switch presentation.state {
        case .submitted: "hourglass"
        case .rejected: "xmark"
        case .unfinished: "list.bullet"
        }
    }

    private var headline: String {
        let name = presentation.serverName
        switch presentation.state {
        case .submitted:
            return name.map { "Your application to join \($0) is awaiting review!" }
                ?? "Your application to join the server is awaiting review."
        case .rejected:
            return name.map { "Your application to join \($0) has been denied." }
                ?? "Your application to join the server has been denied."
        case .unfinished:
            return name.map { "Submit your application to join \($0)." }
                ?? "Submit your application to join the server."
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch presentation.state {
        case .submitted:
            Text("You'll get notified when there's an update.")
                .font(.system(.body, weight: .medium))
                .foregroundStyle(Ink.secondary)
        case .rejected(let reason?, _) where !reason.isEmpty:
            // Discord's label and the moderator's words, in one style.
            Text(verbatim: "Reason: \(reason)")
                .font(.system(.body, weight: .medium))
                .foregroundStyle(Ink.secondary)
        case .rejected, .unfinished:
            EmptyView()
        }
    }

    // MARK: The buttons

    @ViewBuilder
    private var actions: some View {
        switch presentation.state {
        case .submitted:
            StatusPageButton(title: "Withdraw", kind: .destructive) { askToWithdraw(false) }

        case .rejected(_, let canReapply):
            // Side by side, each half the row (`confirmationButtonRow__1051d`).
            HStack(spacing: Spacing.group) {
                if canReapply || presentation.isReapplying {
                    StatusPageButton(
                        title: "Reapply",
                        kind: .secondary,
                        isWorking: presentation.isReapplying,
                        action: reapply
                    )
                }
                StatusPageButton(title: "Withdraw", kind: .destructive) {
                    // Discord asks only where there is something to come back
                    // to — a server that still takes applications.
                    if canReapply { askToWithdraw(false) } else { withdraw() }
                }
            }

        case .unfinished:
            VStack(spacing: Spacing.base) {
                StatusPageButton(title: "Open Application", kind: .secondary, action: openApplication)
                StatusPageButton(title: "Discard Application", kind: .destructive) { askToWithdraw(true) }
            }
        }
    }
}

/// One of the card's buttons: FormSheet's capsules, at the card's full width
/// — solid ink at a real size, which is what a control on glass has to be.
private struct StatusPageButton: View {
    var title: String
    var kind: Kind
    var isWorking = false
    var action: () -> Void

    enum Kind {
        case secondary
        case destructive
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                // The title keeps the button's width while it spins.
                Text(verbatim: title).opacity(isWorking ? 0 : 1)
                if isWorking { ProgressView().controlSize(.small) }
            }
            .font(.system(.body, weight: kind == .secondary ? .medium : .semibold))
            .frame(maxWidth: .infinity)
            .frame(height: Metrics.composerControlHeight)
            .background(kind == .secondary ? Palette.surfaceRaised : Palette.destructive, in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .foregroundStyle(kind == .secondary ? AnyShapeStyle(Ink.primary) : AnyShapeStyle(.white))
        .disabled(isWorking)
    }
}

/// The page, fed from the store.
struct JoinRequestStatusContainer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let presentation = model.joinRequestStatusPresentation {
            let guildID = presentation.guildID
            JoinRequestStatusPane(
                presentation: presentation,
                withdraw: { model.withdrawApplication(guildID) },
                askToWithdraw: { model.askToWithdrawApplication(guildID, isDiscard: $0) },
                reapply: { model.reapply(toGuild: guildID, opensForm: true) },
                openApplication: { model.openJoinApplication(guildID) }
            )
            .equatable()
        }
    }
}
