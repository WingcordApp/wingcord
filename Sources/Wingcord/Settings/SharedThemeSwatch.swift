import SwiftUI
import WingcordCore

/// A shared theme's gradient: its colours evenly along its own CSS angle — the
/// swatch Discord's theme card draws, for Saved Themes and the share sheet.
struct SharedThemeSwatch: View {
    var theme: SharedClientTheme

    var body: some View {
        Canvas { context, size in
            let box = CGRect(origin: .zero, size: size)
            let (start, end) = GradientAxis.endpoints(angle: theme.gradientAngle, in: box)
            context.fill(
                Path(box),
                with: .linearGradient(
                    Gradient(colors: theme.gradientStops.map { Color(hex: $0) }),
                    startPoint: start, endPoint: end
                )
            )
        }
        .accessibilityHidden(true)
    }
}
