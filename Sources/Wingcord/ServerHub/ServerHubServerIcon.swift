import SwiftUI

/// The server's icon on the banner: a squircle, ringed so it lifts off the
/// picture behind it.
struct ServerHubServerIcon: View {
    var url: URL?
    var monogram: String

    private let side = ServerHubMetrics.bannerIconSide
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: side * 0.3) }

    var body: some View {
        ZStack {
            shape.fill(Palette.accent.gradient)
            Text(monogram)
                .font(.system(size: side * 0.32, weight: .bold))
                .foregroundStyle(.white)
            if let url {
                RemoteImage(url: url, side: side) {
                    Color.clear
                }
                .scaledToFill()
            }
        }
        .frame(width: side, height: side)
        .clipShape(shape)
        .overlay { shape.strokeBorder(.white.opacity(0.22), lineWidth: 1) }
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        .accessibilityHidden(true)
    }
}
