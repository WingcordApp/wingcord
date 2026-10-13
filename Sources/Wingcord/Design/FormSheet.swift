import SwiftUI

/// The window's one form sheet: Discord's modal (`m.a` — title, a line under
/// it, the form, then Cancel and the act) in this app's surfaces.
///
/// **Every sheet wears it** — the moderation dialogs, the settings sheets, the
/// create and edit forms — so a Kick and a Create Channel put the same button
/// in the same place, and a fix to one is a fix to all of them. The settings
/// sheets used to be a bare headline over two glass buttons, which is why they
/// read as unfinished next to the dialogs.
///
/// **The system's sheet, with the system's buttons** (DESIGN-NOTES §2.2):
/// no custom ground and no close glyph — Cancel is the way out, on Escape, and
/// the act is the default button, on Return.
///
/// **A tall form scrolls, a short one does not.** `ViewThatFits` offers the
/// form as it is first and the scrolling copy only when the window cannot hold
/// it: a `ScrollView` with no height of its own is how a sheet collapses to a
/// sliver.
struct FormSheet<Content: View>: View {
    var title: String
    var subtitle: Text?
    var confirmTitle: String
    /// Discord's words for the way out where they are not "Cancel" — "Never
    /// mind" over a notice.
    var cancelTitle = "Cancel"
    /// Discord's `critical-primary` — Kick, Ban, Delete.
    var isDestructive = false
    /// A write in flight: the button spins and nothing can be pressed twice.
    var isWorking = false
    /// Whether the act can be pressed. A sheet that accepts an empty name and
    /// answers a 400 is a sheet that made the reader do the validating.
    var canConfirm = true
    /// Closes the sheet once `confirm` has run — for a sheet whose write is the
    /// store's to finish. A dialog that reports its own outcome closes itself.
    var closesOnConfirm = false
    /// Return for a form of single fields; ⌘Return where a text area wants
    /// Return for its own line breaks.
    var confirmShortcut: KeyboardShortcut = .defaultAction
    var width: CGFloat = 440
    var confirm: () -> Void
    @ViewBuilder var content: Content

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ViewThatFits(in: .vertical) {
                form
                ScrollView { form }
                    .scrollBounceBehavior(.basedOnSize)
            }
            footer
        }
        .frame(width: width)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: Spacing.margin) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.group)
        .padding(.bottom, Spacing.margin)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            Text(verbatim: title)
                .font(.system(.title3, weight: .semibold))
                .foregroundStyle(Ink.primary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                subtitle
                    .font(.system(.subheadline))
                    .foregroundStyle(Ink.secondary)
                    .tint(Palette.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, Spacing.group)
        .padding(.top, Spacing.group)
        .padding(.bottom, Spacing.margin)
    }

    private var footer: some View {
        HStack(spacing: Spacing.snug) {
            Spacer(minLength: 0)
            Button(cancelTitle, role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(role: isDestructive ? .destructive : nil) {
                confirm()
                if closesOnConfirm { dismiss() }
            } label: {
                ZStack {
                    // The title keeps the button's width while it spins.
                    Text(verbatim: confirmTitle).opacity(isWorking ? 0 : 1)
                    if isWorking { ProgressView().controlSize(.small) }
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(isDestructive ? Palette.destructive : nil)
            .disabled(isWorking || !canConfirm)
            .keyboardShortcut(confirmShortcut)
        }
        .controlSize(.large)
        .padding(.horizontal, Spacing.group)
        .padding(.vertical, Spacing.margin)
    }
}
