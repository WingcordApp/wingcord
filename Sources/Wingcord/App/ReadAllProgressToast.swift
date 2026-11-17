import SwiftUI

/// Read All, in words and a bar, over the window while it runs — so nobody
/// presses it again thinking nothing happened (Alex, 2026-11-17).
///
/// **The app's own notice, with a bar in it**: the same glass capsule at the
/// same place as every other notice, and gone the moment the work is done,
/// when "Marked N channels as read" takes its place.
struct ReadAllProgressToast: View {
    var progress: ReadAllProgress?

    @Environment(\.motion) private var motion

    var body: some View {
        Group {
            if let progress {
                HStack(spacing: Spacing.snug) {
                    ProgressView()
                        .controlSize(.small)
                    VStack(alignment: .leading, spacing: Spacing.tight) {
                        Text("Marking everything as read\u{2026}")
                            .font(.system(.caption, weight: .semibold))
                            .foregroundStyle(Ink.primary)
                        ProgressView(value: progress.fraction)
                            .progressViewStyle(.linear)
                            .tint(Palette.accent)
                            .frame(width: 180)
                    }
                    Text("\(progress.done) of \(progress.total)")
                        .font(.system(.caption, weight: .medium))
                        .foregroundStyle(Ink.secondary)
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(progress.done)))
                }
                .padding(.horizontal, Spacing.margin)
                .padding(.vertical, Spacing.base + 2)
                .glassEffect(.regular, in: .capsule)
                .padding(.top, Spacing.base)
                .transition(.materialize(from: .top))
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text("Marking everything as read, \(progress.done) of \(progress.total)"))
            }
        }
        .animation(motion.panel, value: progress == nil)
        .animation(motion.standard, value: progress?.done)
    }
}
