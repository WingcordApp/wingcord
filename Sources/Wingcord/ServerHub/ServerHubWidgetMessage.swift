import SwiftUI

/// A card with nothing to show yet: why, and what will fill it — the system's
/// own empty state (`ContentUnavailableView`), sized for a card.
struct ServerHubWidgetMessage: View {
    var symbol: String
    var title: String
    var detail: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
                .font(.system(.headline))
        } description: {
            Text(detail)
                .font(.system(.callout))
        }
        .foregroundStyle(Ink.secondary)
        .frame(maxWidth: .infinity, minHeight: 160)
        .padding(.vertical, Spacing.base)
    }
}
