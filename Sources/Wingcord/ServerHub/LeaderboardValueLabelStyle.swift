import SwiftUI

/// The value's glyph a hair smaller and quieter than its number.
struct LeaderboardValueLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Ink.secondary)
            configuration.title
        }
    }
}
