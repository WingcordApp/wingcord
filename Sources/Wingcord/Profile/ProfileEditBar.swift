import SwiftUI

/// The bar that appears when the profile has unsaved changes.
///
/// **It is the only thing that commits.** Every control in the editor writes to
/// the draft and nothing else — there is no control that saves by itself — so
/// the reader can change five things, look at the result, and take all of it
/// back with one button. That is also what makes `Reset` meaningful: without a
/// single commit point it would have to undo five requests that already landed.
///
/// **Floating over the sheet's foot rather than pinned under it**, which is the
/// arrangement the identity panel's own dock already uses: a bar that took a
/// strip out of the layout would resize the profile the moment it appeared, and
/// the profile is what the reader is looking at.
struct ProfileEditBar: View {
    var editor: ProfileEditor
    var save: () -> Void

    @Environment(\.motion) private var motion

    var body: some View {
        HStack(spacing: Spacing.snug) {
            message
            Spacer(minLength: Spacing.group)
            Button("Reset", action: editor.reset)
                .buttonStyle(.plain)
                .font(.system(.subheadline, weight: .medium))
                .foregroundStyle(InkColor.primary)
                .padding(.horizontal, Spacing.margin)
                .frame(height: Metrics.control)
                .interactiveChromeOverMedia(in: .rect(cornerRadius: 8, style: .continuous))
                .disabled(editor.isSaving)

            Button(action: save) {
                // The label holds its width while the spinner is up, so the bar
                // does not reflow at the exact moment the reader is watching it.
                Text("Save")
                    .opacity(editor.isSaving ? 0 : 1)
                    .overlay {
                        if editor.isSaving {
                            ProgressView().controlSize(.small)
                        }
                    }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(editor.isSaving)
            .keyboardShortcut(.return, modifiers: .command)
        }
        // **Hugging, not spanning.** A bar the width of the sheet reads as a
        // second toolbar bolted to the foot; sized to its own words it reads as
        // a message about the edit, which is what it is.
        .fixedSize(horizontal: true, vertical: false)
        .padding(.leading, Spacing.margin)
        .padding(.trailing, Spacing.base)
        .padding(.vertical, Spacing.base)
        .background {
            RoundedRectangle(cornerRadius: Radius.glass, style: .continuous)
                .fill(Palette.surfaceRaised)
                .shadow(color: .black.opacity(0.45), radius: 20, y: 8)
        }
        .animation(motion.standard, value: editor.isSaving)
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
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Palette.destructive)
            }
            .font(Typeface.rowSubtitle)
            .foregroundStyle(InkColor.primary)
        } else {
            Text("You have unsaved changes.")
                .font(.system(.subheadline, weight: .medium))
                .foregroundStyle(InkColor.primary)
                .lineLimit(1)
        }
    }
}
