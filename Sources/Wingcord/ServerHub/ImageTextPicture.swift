import AppKit
import SwiftUI

/// The widget's picture, whole — never cropped, since it's somebody's poster.
struct ImageTextPicture: View {
    var url: URL?
    var preview: Data?

    var body: some View {
        Group {
            if let preview, let image = NSImage(data: preview) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                RemoteImage(url: url, side: 840, bucket: .artwork) {
                    RoundedRectangle(cornerRadius: 12).fill(Palette.hoverFill)
                        .frame(height: 180)
                }
                .scaledToFit()
            }
        }
        .clipShape(.rect(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Ink.quaternary, lineWidth: 1) }
        .accessibilityHidden(true)
    }
}
