import SwiftUI

/// A standing note in a sheet — a report node's "if there is immediate
/// danger…", the nickname warning, a ban's missing reason. Discord's `Notice`.
struct Callout: View {
    var text: String
    var symbolName: String = "info.circle.fill"
    var tint: Color = Palette.accent

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.base) {
            Image(symbol: symbolName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(.subheadline))
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(Spacing.snug)
        .background(tint.opacity(0.10), in: .rect(cornerRadius: Radius.chip, style: .continuous))
    }
}
