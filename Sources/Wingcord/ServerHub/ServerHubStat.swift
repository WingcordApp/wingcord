import SwiftUI

/// One count under the server's name: a dot or a glyph, and the words.
struct ServerHubStat: View {
    var text: String
    var dot: Color?
    var systemImage: String?

    var body: some View {
        HStack(spacing: 6) {
            if let dot {
                Circle()
                    .fill(dot)
                    .frame(width: 8, height: 8)
            } else if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .bold))
            }
            Text(text)
                .font(.system(.callout, weight: .semibold))
        }
        .foregroundStyle(.white.opacity(0.92))
        .shadow(color: .black.opacity(0.3), radius: 4, y: 1)
    }
}
