import SwiftUI

/// What the report is about: a choice of a few, guessed from where the reader
/// was and theirs to change — a pop-up of mutually exclusive options with a
/// useful default (HIG, Pop-up buttons), in the app's glass flyout.
struct BugAreaRow: View {
    @Binding var area: BugArea

    var body: some View {
        HStack(spacing: Spacing.snug) {
            Text("Area")
                .font(.system(.subheadline, weight: .medium))
                .foregroundStyle(Ink.primary)
            Spacer(minLength: Spacing.base)
            FlyoutPicker(
                selection: $area,
                options: BugArea.allCases,
                title: \.title,
                symbol: { $0.symbolName },
                accessibilityTitle: "Area",
                flyoutWidth: 240
            )
        }
    }
}
