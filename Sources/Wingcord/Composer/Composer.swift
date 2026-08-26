import SwiftUI
import WingcordCore

/// The composer, floating over the foot of the transcript.
///
/// **Plain glass, not `.interactive()`.** Interactive glass adds a hover
/// highlight and a displacement toward the cursor; on a bar this wide that reads
/// as the whole composer shifting under the pointer rather than as a control
/// responding. The composer also has no press or focus highlight at all — it is
/// one flat plate in every state, because hand-rolling a focus lift means
/// layering a gesture over the text field where it competes with caret placement
/// and selection.
///
/// **`+` sits outside the plate.** At the plate's corner radius an enclosed
/// circle collides with the rounded end, which is the whole reason Discord's own
/// composer is a rounded rect rather than a capsule. Keeping `+` beside the
/// plate lets the plate keep its radius and lets `+` keep its circle.
///
/// Colour is reserved for meaning: the send control is the only tinted thing
/// here, and only once there is something to send.
struct Composer: View {
    var channelName: String
    var canSend: Bool
    var replyingToAuthor: String?
    @Binding var text: String

    var send: () -> Void = {}
    var cancelReply: () -> Void = {}
    var attach: () -> Void = {}

    @Environment(\.motion) private var motion
    @FocusState private var isFocused: Bool

    private var hasText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: Spacing.tight) {
            if let replyingToAuthor {
                ReplyBanner(author: replyingToAuthor, cancel: cancelReply)
                    .transition(.materialize(from: .bottom))
            }

            if canSend {
                composerRow
            } else {
                PermissionNotice()
            }
        }
        .padding(.horizontal, Spacing.margin)
        .padding(.bottom, Spacing.snug)
        .animation(motion.panel, value: replyingToAuthor)
        .animation(motion.standard, value: canSend)
    }

    private var composerRow: some View {
        HStack(alignment: .bottom, spacing: Spacing.base) {
            CircleControl(systemImage: "plus", label: "Add attachment", action: attach)

            HStack(alignment: .bottom, spacing: Spacing.base) {
                TextField(
                    "Message #\(channelName)",
                    text: $text,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .font(Typeface.messageBody)
                // White across the whole bar rather than the hierarchy: a
                // `.secondary` glyph washes out on glass, and a composer whose
                // placeholder is invisible reads as broken.
                .foregroundStyle(.white)
                .lineLimit(1...Metrics.composerMaxLines)
                .focused($isFocused)
                .onSubmit(send)
                .frame(minHeight: Metrics.composerFieldMinHeight)

                if hasText {
                    SendControl(action: send)
                        .transition(.materialize(from: .trailing))
                }
            }
            .padding(.horizontal, Spacing.snug)
            .padding(.vertical, Spacing.tight)
            .glassEffect(.regular, in: .rect(cornerRadius: Radius.glass))
            .animation(motion.glassMorph, value: hasText)
        }
        .contentShape(.rect)
        // Clicking anywhere on the bar puts the caret in the field, which is
        // what every composer on this platform does.
        .onTapGesture { isFocused = true }
    }
}

/// A circular glass control beside the composer.
private struct CircleControl: View {
    var systemImage: String
    var label: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(Typeface.controlGlyph)
                .foregroundStyle(.white)
                .frame(
                    width: Metrics.composerControlHeight,
                    height: Metrics.composerControlHeight
                )
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        // Small discrete targets keep `.interactive()` — the displacement scales
        // with the surface, so on a 38pt circle it reads as the control
        // responding rather than as the bar moving.
        .interactiveChrome(in: .circle)
        .help(label)
        .accessibilityLabel(Text(label))
    }
}

/// The send control. The one tinted thing in the composer, and only once there
/// is something to send.
private struct SendControl: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up")
                .font(.system(.body, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .emphasisChrome(Palette.accent, in: .circle)
        .keyboardShortcut(.return, modifiers: [])
        .accessibilityLabel(Text("Send"))
    }
}

private struct ReplyBanner: View {
    var author: String
    var cancel: () -> Void

    var body: some View {
        HStack(spacing: Spacing.base) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .font(.system(.caption))
                .foregroundStyle(Ink.tertiary)
            Text("Replying to \(author)")
                .font(.system(.caption))
                .foregroundStyle(Ink.secondary)
                .lineLimit(1)
            Spacer(minLength: Spacing.tight)
            Button(action: cancel) {
                Image(systemName: "xmark")
                    .font(.system(.caption2, weight: .bold))
                    .foregroundStyle(Ink.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Cancel reply"))
        }
        .padding(.horizontal, Spacing.snug)
        .padding(.vertical, Spacing.base)
        .glassEffect(.regular, in: .rect(cornerRadius: Radius.chip))
    }
}

/// What stands in for the composer where the reader cannot post.
///
/// Deliberately the same shape and the same glass as the composer it replaces,
/// so the foot of the transcript does not change height when navigating between
/// a channel you can post in and one you cannot.
private struct PermissionNotice: View {
    var body: some View {
        HStack(spacing: Spacing.base) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(.caption))
                .foregroundStyle(Ink.tertiary)
            Text("You do not have permission to send messages in this channel.")
                .font(.system(.subheadline))
                .foregroundStyle(Ink.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.snug)
        .frame(minHeight: Metrics.composerControlHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: Radius.glass))
    }
}
