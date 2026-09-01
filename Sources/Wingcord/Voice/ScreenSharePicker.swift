import SwiftUI
import WingcordVoice

// MARK: - What to share
//
// A grid of what ScreenCaptureKit says can be shared: the displays first, then
// every window big enough and titled enough to be somebody's actual work.
//
// **There is no authorisation-status API for screen capture.** Unlike the camera
// and the microphone, the only way to find out whether Screen Recording has been
// granted is to ask for the content and see whether it throws — which is why a
// failure here sends the reader to System Settings rather than reporting an
// error they can do nothing about.
struct ScreenSharePicker: View {
    var start: (ShareableTarget) -> Void
    var dismiss: () -> Void

    @Environment(\.motion) private var motion
    @State private var targets: [ShareableTarget] = []
    @State private var selected: ShareableTarget?
    @State private var failure: String?
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            content
            footer
        }
        .frame(width: 560, height: 460)
        .task { await load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            Text("Share Your Screen")
                .font(.system(.headline, weight: .semibold))
                .foregroundStyle(Ink.primary)
            Text("Everyone in the call will see this until you stop.")
                .font(.system(.subheadline))
                .foregroundStyle(Ink.tertiary)
        }
        .padding(Spacing.margin)
    }

    @ViewBuilder
    private var content: some View {
        if let failure {
            permissionState(failure)
        } else if isLoading {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            grid
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: Spacing.snug),
                    GridItem(.flexible(), spacing: Spacing.snug),
                ],
                spacing: Spacing.snug
            ) {
                ForEach(targets) { target in
                    card(target)
                }
            }
            .padding(.horizontal, Spacing.margin)
            .padding(.bottom, Spacing.margin)
        }
        .scrollIndicators(.automatic)
    }

    private func card(_ target: ShareableTarget) -> some View {
        Button {
            withAnimation(motion.standard) { selected = target }
        } label: {
            VStack(alignment: .leading, spacing: Spacing.base) {
                ZStack {
                    RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                        .fill(Palette.surfaceRaised)
                    Image(systemName: isDisplay(target) ? "display" : "macwindow")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(Ink.tertiary)
                }
                .frame(height: 96)

                VStack(alignment: .leading, spacing: 1) {
                    Text(target.title)
                        .font(.system(.subheadline, weight: .medium))
                        .foregroundStyle(Ink.primary)
                        .lineLimit(1)
                    Text(target.application ?? "\(target.width) × \(target.height)")
                        .font(.system(.caption))
                        .foregroundStyle(Ink.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(Spacing.base)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: Radius.glass, style: .continuous)
                .fill(selected == target ? Palette.selectionFill : Palette.hoverFill.opacity(0.5))
        }
        .overlay {
            RoundedRectangle(cornerRadius: Radius.glass, style: .continuous)
                .strokeBorder(
                    selected == target ? Palette.accent : Color.white.opacity(0.06),
                    lineWidth: selected == target ? 2 : 1
                )
        }
        .accessibilityLabel(Text(target.title))
        .accessibilityAddTraits(selected == target ? [.isSelected, .isButton] : .isButton)
    }

    private func permissionState(_ message: String) -> some View {
        VStack(spacing: Spacing.snug) {
            Image(systemName: "lock.display")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Ink.quaternary)
            Text("Wingcord needs permission to record the screen")
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(Ink.secondary)
            Text(message)
                .font(.system(.caption))
                .foregroundStyle(Ink.tertiary)
                .multilineTextAlignment(.center)
            Button("Open System Settings") {
                guard let url = URL(
                    string: "x-apple.systempreferences:com.apple.preference.security"
                        + "?Privacy_ScreenCapture"
                ) else { return }
                NSWorkspace.shared.open(url)
            }
            .buttonStyle(.glass)
            .controlSize(.small)
        }
        .padding(Spacing.group)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: Spacing.base) {
            Spacer(minLength: 0)
            Button("Cancel", action: dismiss)
                .buttonStyle(.glass)
                .keyboardShortcut(.cancelAction)
            Button("Share") {
                guard let selected else { return }
                start(selected)
            }
            .buttonStyle(.glassProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(selected == nil)
        }
        .controlSize(.regular)
        .padding(Spacing.margin)
    }

    private func isDisplay(_ target: ShareableTarget) -> Bool {
        if case .display = target.kind { return true }
        return false
    }

    private func load() async {
        do {
            let found = try await ScreenShareCapture.shareable()
            targets = found
            selected = found.first
            isLoading = false
        } catch {
            failure = error.localizedDescription
            isLoading = false
        }
    }
}
