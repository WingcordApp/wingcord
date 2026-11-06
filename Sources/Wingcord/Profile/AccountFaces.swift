import SwiftUI

/// The other accounts' pictures, overlapping, on the card's row.
struct AccountFaces: View {
    var accounts: [StoredAccount]

    private static let side: CGFloat = 18
    /// Past three is a pile, and the flyout's where they're counted.
    private static let shown = 3

    var body: some View {
        HStack(spacing: -5) {
            ForEach(accounts.prefix(Self.shown)) { account in
                AvatarView(url: account.avatarURL(side: Self.side), monogram: account.monogram, side: Self.side)
                    .overlay {
                        Circle().strokeBorder(.background.opacity(0.6), lineWidth: 1)
                    }
            }
        }
        .accessibilityHidden(true)
    }
}
