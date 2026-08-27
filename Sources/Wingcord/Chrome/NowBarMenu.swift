import SwiftUI
import WingcordCore

/// What the identity capsule opens: who you are, what you are showing, and the
/// two things you can do about it.
///
/// **The status list is the point and it is drawn as one.** Discord puts this
/// behind a menu; a menu is a list of *commands*, and four of these six rows are
/// a single-choice control whose current value has to be visible. So the
/// statuses are rows with their own presence marks and a check on the live one —
/// what you are is readable before you press anything, which is the question the
/// control is opened to answer.
///
/// **The popover's own material is the panel**, and this draws no background of
/// its own — the two profile cards each carry theirs and clear the popover's,
/// and doing both here would be glass on glass. A menu is exactly what the
/// system's popover material is for.
///
/// Setting a custom status swaps this panel's contents rather than opening a
/// second surface over it. A popover on a popover for one text field is two
/// dismissals, two escapes and a second thing to place; the panel is already
/// exactly where the reader is looking.
struct NowBarMenu: View {
    var presentation: NowBarPresentation
    var setStatus: (PresenceStatus) -> Void
    var setCustomStatus: (String?) -> Void
    var openSelfProfile: () -> Void
    var dismiss: () -> Void

    @Environment(\.motion) private var motion
    @State private var isEditingStatus = false
    @State private var draft = ""
    @FocusState private var isFieldFocused: Bool

    private static let width: CGFloat = 260

    /// The four a person can choose. `.offline` is not one of them — it is what
    /// *other* people are, and picking it is what Invisible means.
    private static let choices: [PresenceStatus] = [
        .online, .idle, .doNotDisturb, .invisible,
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            identity
            Divider().opacity(0.4).padding(.vertical, Spacing.base)

            if isEditingStatus {
                editor
            } else {
                statusList
                Divider().opacity(0.4).padding(.vertical, Spacing.base)
                actions
            }
        }
        .padding(.vertical, Spacing.snug)
        .frame(width: Self.width)
        .animation(motion.standard, value: isEditingStatus)
    }

    // MARK: Identity

    private var identity: some View {
        HStack(spacing: Spacing.base) {
            AvatarView(
                url: presentation.avatarURL,
                monogram: presentation.monogram,
                side: Metrics.avatarRow + 6
            )
            .overlay(alignment: .bottomTrailing) {
                PresenceDot(status: presentation.status, side: 11)
                    .offset(x: 2, y: 2)
            }

            VStack(alignment: .leading, spacing: 0) {
                Text(presentation.displayName)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                Text("@\(presentation.handle)")
                    .font(Typeface.rowSubtitle)
                    .foregroundStyle(Ink.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.snug)
        .accessibilityElement(children: .combine)
    }

    // MARK: Status

    private var statusList: some View {
        VStack(spacing: 0) {
            ForEach(Self.choices, id: \.self) { status in
                MenuRow(
                    isChecked: status == presentation.status,
                    action: {
                        setStatus(status)
                        dismiss()
                    },
                    label: {
                        PresenceDot(status: status, side: 10, hasPlate: false)
                            .frame(width: 14)
                        Text(status.label)
                            .foregroundStyle(Ink.primary)
                    }
                )
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 0) {
            MenuRow(
                isChecked: false,
                action: {
                    draft = presentation.customStatus ?? ""
                    isEditingStatus = true
                    isFieldFocused = true
                },
                label: {
                    Image(systemName: "face.smiling")
                        .foregroundStyle(Ink.secondary)
                        .frame(width: 14)
                    Text(presentation.customStatus == nil
                        ? "Set a Custom Status"
                        : "Edit Custom Status")
                        .foregroundStyle(Ink.primary)
                }
            )
            MenuRow(
                isChecked: false,
                action: {
                    openSelfProfile()
                    dismiss()
                },
                label: {
                    Image(systemName: "person.crop.circle")
                        .foregroundStyle(Ink.secondary)
                        .frame(width: 14)
                    Text("View Profile")
                        .foregroundStyle(Ink.primary)
                }
            )
        }
    }

    // MARK: The editor

    private var editor: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            TextField("What's happening?", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(.subheadline))
                .foregroundStyle(.white)
                .focused($isFieldFocused)
                .onSubmit(commit)
                .padding(.horizontal, Spacing.base)
                .padding(.vertical, Spacing.base)
                .glassEffect(.regular, in: .rect(cornerRadius: Radius.row))

            HStack(spacing: Spacing.base) {
                // Clearing is offered only when there is something to clear —
                // a Clear that does nothing is a control that teaches people to
                // ignore the row it is in.
                if presentation.customStatus?.isEmpty == false {
                    Button("Clear", role: .destructive) {
                        setCustomStatus(nil)
                        dismiss()
                    }
                    .buttonStyle(.glass)
                }
                Spacer(minLength: 0)
                Button("Save", action: commit)
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, Spacing.snug)
        .transition(.materialize(from: .top))
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        setCustomStatus(trimmed.isEmpty ? nil : trimmed)
        dismiss()
    }
}

/// One row in the panel.
///
/// Its own type because six rows sharing a hover ground, a height and a check
/// column by copy is six places for one of them to drift — and the check column
/// is reserved on **every** row, so the labels line up whether or not anything
/// is ticked.
private struct MenuRow<Label: View>: View {
    var isChecked: Bool
    var action: () -> Void
    @ViewBuilder var label: Label

    @Environment(\.motion) private var motion
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.base) {
                label
                Spacer(minLength: Spacing.base)
                Image(systemName: "checkmark")
                    .font(.system(.caption, weight: .bold))
                    .foregroundStyle(Palette.accent)
                    .opacity(isChecked ? 1 : 0)
            }
            .font(.system(.subheadline))
            .padding(.horizontal, Spacing.base)
            .frame(minHeight: Metrics.rowMinHeight)
            .background {
                RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                    .fill(Palette.hoverFill)
                    .opacity(isHovering ? 1 : 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Spacing.base)
        .onHover { hovering in
            // A `@State` write of an equal value still invalidates.
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .animation(motion.hover, value: isHovering)
        .accessibilityAddTraits(isChecked ? [.isButton, .isSelected] : .isButton)
    }
}
