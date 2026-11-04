import SwiftUI

/// The window's one form card: Discord's modal (`m.a` — title, a line under
/// it, the form, then Cancel and the act) as Wingcord's Form card (D11b).
///
/// **Every form wears it** — the moderation dialogs, the settings forms, the
/// create and edit forms — so a Kick and a Create Channel put the same button
/// in the same place, and a fix to one is a fix to all of them.
///
/// **A card, with Liquid Glass capsules** (docs/SHEETS-SETTINGS.md D11, which
/// retired DESIGN-NOTES §2.2's "the system's sheet, with the system's
/// buttons"): Cancel leading, on Escape; the act trailing in the theme's
/// accent, on Return — or ⌘Return where a text area wants Return for its
/// lines. An act that cannot be undone (`isDestructive` — Kick, Ban, Delete)
/// keeps the accent and gives up Return, so it is read before it is pressed;
/// red is for a destruction nobody chose, which a form never asks for.
///
/// **A tall form scrolls, a short one does not.** `ViewThatFits` offers the
/// form as it is first and the scrolling copy only when the window cannot hold
/// it: a `ScrollView` with no height of its own is how a card collapses to a
/// sliver.
struct FormSheet<Content: View>: View {
    var title: String
    var subtitle: Text?
    var confirmTitle: String
    /// Discord's words for the way out where they are not "Cancel" — "Never
    /// mind" over a notice.
    var cancelTitle = "Cancel"
    /// Discord's `critical-primary` — Kick, Ban, Delete: an act that cannot be
    /// undone, so it takes no Return.
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
    /// The act's symbol, beside its word.
    var confirmSymbol: String? = nil
    var confirm: () -> Void
    @ViewBuilder var content: Content

    @ModalDismiss private var dismiss

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
                .font(.system(.title2, weight: .bold))
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
        GlassEffectContainer(spacing: Spacing.snug) {
            HStack(spacing: Spacing.snug) {
                ModalButton(title: cancelTitle, symbolName: "xmark", role: .cancel) { dismiss() }
                Spacer(minLength: 0)
                ModalButton(
                    title: confirmTitle,
                    symbolName: confirmSymbol,
                    role: .act,
                    isIrreversible: isDestructive,
                    isWorking: isWorking,
                    shortcut: isDestructive ? nil : confirmShortcut
                ) {
                    confirm()
                    if closesOnConfirm { dismiss() }
                }
                .disabled(!canConfirm)
            }
        }
        .padding(.horizontal, Spacing.margin)
        .padding(.top, Spacing.base)
        .padding(.bottom, Spacing.margin)
    }
}
