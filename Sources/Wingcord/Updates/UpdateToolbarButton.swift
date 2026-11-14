import SwiftUI

/// Discord's green arrow, at the trailing end of the toolbar row, while an
/// update is found or ready (docs/UPDATES.md D8).
///
/// **Nothing else asks for attention.** Discord's client says an update is ready
/// this way and no other, and so does this one: no window, no notification, no
/// badge. A ready update opens its card; one that isn't downloaded yet — only
/// when automatic installs are off — brings Sparkle's own window forward.
struct UpdateToolbarButton: View {
    @State private var updates = AppUpdates.shared
    @Environment(\.headerControlSide) private var side
    @Environment(\.motion) private var motion

    /// Discord's green, which its own update arrow wears.
    static let green = Color(hex: 0x23A55A)

    var body: some View {
        // A Group, so an absent arrow takes no room and no spacing in the row,
        // and its arrival still moves on the panel's spring.
        Group {
            if let update = shown { arrow(update) }
        }
        .animation(motion.panel, value: shown?.build)
    }

    private func arrow(_ update: AppUpdates.Update) -> some View {
        Button { updates.arrowPressed() } label: {
            Image(systemName: "arrow.down.to.line")
                .font(.system(size: ShellMetrics.headerGlyph, weight: .semibold))
                .foregroundStyle(Self.green)
                .frame(width: side, height: side)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .help(label(update))
        .accessibilityLabel(Text(label(update)))
        .popover(isPresented: $updates.isCardShown, arrowEdge: .bottom) {
            UpdateCard(update: update)
        }
        .transition(.materialize(from: .trailing, blurring: false))
    }

    private var shown: AppUpdates.Update? {
        switch updates.state {
        case .idle: nil
        case .available(let update), .ready(let update): update
        }
    }

    private func label(_ update: AppUpdates.Update) -> String {
        if case .ready = updates.state { return "Wingcord \(update.displayVersion) Is Ready to Install" }
        return "Wingcord \(update.displayVersion) Is Available"
    }
}

/// What a ready update says under its arrow: its name, what's new, and Restart
/// Now — or, during a call, a restart once the call is over.
struct UpdateCard: View {
    var update: AppUpdates.Update

    @Environment(AppModel.self) private var model
    @State private var updates = AppUpdates.shared

    static let width: CGFloat = 380

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 20)
                // With no notes the footer's own padding is the whole gap.
                .padding(.bottom, update.notes == nil ? 0 : 12)
            if let notes = update.notes {
                ScrollView {
                    // RenderedMarkdown insets itself 16; four more lines its text
                    // up with the name above and the line beside the button.
                    RenderedMarkdown(text: notes, notice: "")
                        .padding(.horizontal, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 300)
                .fixedSize(horizontal: false, vertical: true)
            }
            footer
                .padding(20)
        }
        .frame(width: Self.width)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "Wingcord \(update.displayVersion)")
                    .font(.headline)
                    .foregroundStyle(Ink.primary)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Ink.secondary)
            }
        }
    }

    private var subtitle: String {
        if updates.restartsAfterCall { return "Installs when your call ends" }
        return update.isCritical ? "An important update, ready to install" : "Ready to install"
    }

    @ViewBuilder
    private var footer: some View {
        let inCall = model.connectedVoiceChannelID != nil
        HStack(spacing: 10) {
            if updates.restartsAfterCall {
                Spacer()
                ModalButton(title: "Don't Wait", role: .cancel) { updates.cancelRestartAfterCall() }
            } else {
                Text(inCall ? "Wingcord restarts once you leave the call." : "It also installs when you quit.")
                    .font(.subheadline)
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                // No Return: a restart closes every window, so it's never one stray key away.
                ModalButton(
                    title: inCall ? "After the Call" : "Restart Now",
                    symbolName: "arrow.clockwise",
                    isIrreversible: true
                ) {
                    updates.restart(model: model)
                }
            }
        }
    }
}
