import SwiftUI

/// The bar that appears when the profile has unsaved changes.
///
/// **It is the only thing that commits.** Every control in the editor writes to
/// the draft and nothing else — there is no control that saves by itself — so
/// the reader can change five things, look at the result, and take all of it
/// back with one button.
///
/// **Liquid Glass, after Discord's own** (Alex's screenshots 15 and 16):
/// "Careful — you have unsaved changes!", a Reset and a Save Changes, as a
/// floating capsule of glass with capsule buttons — the HIG's shape for a bar
/// that floats over content, and its prominent glass for the one action that
/// matters. **It floats over the sheet's foot rather than taking a strip out of
/// the layout**, so it never resizes the profile the reader is looking at.
///
/// **Closing with changes unsaved does not throw them away.** The bar shakes
/// and turns red instead — Discord's own answer — and the trackpad bumps
/// (`ProfileEditor.nudge`).
struct ProfileEditBar: View {
    var editor: ProfileEditor
    var save: () -> Void

    @Environment(\.motion) private var motion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Red for a moment after a nudge.
    @State private var isWarning = false

    var body: some View {
        HStack(spacing: Spacing.snug) {
            message
                .padding(.leading, Spacing.tight)
            Spacer(minLength: Spacing.group)
            Button("Reset", action: editor.reset)
                .buttonStyle(.glass)
                .disabled(editor.isSaving)

            Button(action: save) {
                // The label holds its width while the spinner is up, so the bar
                // does not reflow at the exact moment the reader is watching it.
                Text("Save Changes")
                    .opacity(editor.isSaving ? 0 : 1)
                    .overlay {
                        if editor.isSaving {
                            ProgressView().controlSize(.small)
                        }
                    }
            }
            .buttonStyle(.glassProminent)
            .disabled(editor.isSaving)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        // **Hugging, not spanning.** A bar the width of the sheet reads as a
        // second toolbar bolted to the foot; sized to its own words it reads as
        // a message about the edit, which is what it is.
        .fixedSize(horizontal: true, vertical: false)
        .padding(.leading, Spacing.margin)
        .padding(.trailing, Spacing.base)
        .padding(.vertical, Spacing.base)
        .glassEffect(
            isWarning ? .regular.tint(Palette.destructive.opacity(0.55)) : .regular,
            in: .capsule
        )
        .shadow(color: .black.opacity(0.3), radius: 18, y: 6)
        .keyframeAnimator(initialValue: CGFloat.zero, trigger: editor.nudges) { content, offset in
            content.offset(x: offset)
        } keyframes: { _ in
            if reduceMotion {
                LinearKeyframe(0, duration: 0.01)
            } else {
                SpringKeyframe(-14, duration: 0.07, spring: .snappy)
                SpringKeyframe(12, duration: 0.08, spring: .snappy)
                SpringKeyframe(-8, duration: 0.08, spring: .snappy)
                SpringKeyframe(5, duration: 0.08, spring: .snappy)
                SpringKeyframe(0, duration: 0.16, spring: .smooth)
            }
        }
        .onChange(of: editor.nudges) {
            isWarning = true
            Task {
                try? await Task.sleep(for: .seconds(1.6))
                isWarning = false
            }
        }
        .animation(motion.standard, value: editor.isSaving)
        .animation(motion.fade, value: isWarning)
        .accessibilityElement(children: .contain)
    }

    /// What the bar says, which is **the failure where there is one**.
    ///
    /// A save that was refused and a save that has not happened yet are
    /// different states, and a bar that says "don't forget to save" after
    /// Discord rejected the request is telling the reader to press the button
    /// that just failed.
    @ViewBuilder
    private var message: some View {
        if let failure = editor.failure {
            Label {
                Text(failure)
                    .lineLimit(2)
                    .frame(maxWidth: 320, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Palette.destructive)
            }
            .font(.system(.subheadline, weight: .medium))
            .foregroundStyle(InkColor.primary)
        } else if let progress = editor.clipUploadProgress {
            // A clip is tens of megabytes; a spinner alone for that long reads
            // as a hang.
            Text("Uploading clips… \(Int((progress * 100).rounded()))%")
                .font(.system(.subheadline, weight: .medium))
                .foregroundStyle(InkColor.primary)
                .monospacedDigit()
                .lineLimit(1)
        } else {
            Text("Careful — you have unsaved changes!")
                .font(.system(.subheadline, weight: .medium))
                .foregroundStyle(InkColor.primary)
                .lineLimit(1)
        }
    }
}
