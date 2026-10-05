import SwiftUI

/// One row of the search field's suggestion list.
///
/// **A person, a channel, or the grammar itself** — three shapes behind one view
/// rather than three views, because the list mixes them and a branch at the call
/// site would give the row three identities.
struct SearchSuggestionRow: View {
    var suggestion: SearchSuggestion

    var body: some View {
        HStack(spacing: Spacing.base) {
            leading
            Text(suggestion.title)
                .font(.system(.body, weight: .medium))
                .foregroundStyle(Ink.primary)
                .lineLimit(1)
            if let detail = suggestion.detail {
                Text(detail)
                    .font(.system(.body))
                    .foregroundStyle(Ink.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var leading: some View {
        if let url = suggestion.avatarURL, let monogram = suggestion.monogram {
            AvatarView(url: url, monogram: monogram, side: Metrics.avatarRow)
        } else if let monogram = suggestion.monogram {
            AvatarView(url: nil, monogram: monogram, side: Metrics.avatarRow)
        } else if let symbolName = suggestion.symbolName {
            Image(symbol: symbolName)
                .font(.system(.callout))
                .foregroundStyle(Ink.tertiary)
                .frame(width: Metrics.avatarRow, height: Metrics.avatarRow)
        }
    }
}
