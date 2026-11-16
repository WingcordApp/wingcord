import AppKit
import SwiftUI

/// The banner's picture: one picked in this edit, the hub's or the server's,
/// or — with none — the server's brand colour as a soft gradient.
struct ServerHubBannerArt: View {
    var header: ServerHubPresentation.Header

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                fallback
                if let preview = header.bannerPreview, let image = NSImage(data: preview) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else if let url = header.bannerURL {
                    RemoteImage(url: url, side: max(proxy.size.width, 1), bucket: .artwork, arrival: .easeOut(duration: 0.25)) {
                        Color.clear
                    }
                    .scaledToFill()
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .accessibilityHidden(true)
    }

    private var fallback: some View {
        let base = header.tint.map { Color(hex: $0) } ?? Palette.accent
        return LinearGradient(
            colors: [base.opacity(0.95), base.opacity(0.55), Color.black.opacity(0.6)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
