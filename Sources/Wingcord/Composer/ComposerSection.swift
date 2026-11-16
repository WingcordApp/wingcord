import SwiftUI

/// One part of the composer's glass over the words — a reply's or an edit's
/// header, a schedule, the staged files — and the hairline under it that parts
/// it from what follows (Alex, 2026-11-16, screenshots 30 and 31).
///
/// **It draws no material.** It is a region of the plate it sits in, as the
/// send divider is: a second sheet of glass over the first is the doubled
/// surface `INVARIANTS.md` §4 rule 2 forbids, and it is what made the old reply
/// strip read as a separate object floating over the bar.
struct ComposerSection<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
            // In from the plate's edge by its text inset, so the rule stops
            // short of the rounded corners rather than running into them.
            Rectangle()
                .fill(Ink.quaternary)
                .frame(height: 1)
                .padding(.horizontal, Spacing.snug)
                .accessibilityHidden(true)
        }
    }
}
