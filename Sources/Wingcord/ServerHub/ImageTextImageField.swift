import AppKit
import SwiftUI

/// The picture in the Image + Text form: what's there now, and Upload or Remove.
struct ImageTextImageField: View {
    var preview: Data?
    var currentURL: URL?
    var pick: () -> Void
    var remove: () -> Void

    private var hasPicture: Bool { preview != nil || currentURL != nil }

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.margin) {
            Group {
                if let preview, let image = NSImage(data: preview) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else if let currentURL {
                    RemoteImage(url: currentURL, side: 160) {
                        Palette.hoverFill
                    }
                    .scaledToFill()
                } else {
                    ZStack {
                        Palette.hoverFill
                        Image(systemName: "photo")
                            .foregroundStyle(Ink.tertiary)
                    }
                }
            }
            .frame(width: 120, height: 72)
            .clipShape(.rect(cornerRadius: 10))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.base) {
                Button(hasPicture ? "Change Image\u{2026}" : "Upload Image\u{2026}", action: pick)
                if hasPicture {
                    Button("Remove", role: .destructive, action: remove)
                }
            }
            .buttonStyle(.bordered)
            Spacer(minLength: 0)
        }
    }
}
