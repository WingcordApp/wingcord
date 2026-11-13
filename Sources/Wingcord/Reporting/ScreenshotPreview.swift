import AppKit
import SwiftUI

/// The picture that would go with the report, small, on the card's well —
/// shown the moment its checkbox is ticked, so nobody sends a picture they
/// have not seen.
struct ScreenshotPreview: View {
    var image: NSImage

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: 150)
            .clipShape(.rect(cornerRadius: Radius.chip))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.chip)
                    .strokeBorder(Palette.edge, lineWidth: 1)
            }
            .padding(.leading, 22)
            .accessibilityLabel(Text("Picture of the Wingcord window"))
    }
}
