import SwiftUI

/// The small asset that rides the corner of an activity's artwork.
///
/// **Nothing at all until its picture has arrived.** The badge used to be a
/// plate and a ring with the picture laid in when it came, and a small asset
/// that never comes — a key the CDN has nothing for, as Crunchyroll's is — left
/// the plate and the ring: an empty black disc on the corner of the poster.
/// Discord draws no badge there, so neither does this.
struct ActivityArtBadge: View {
    var url: URL
    var side: CGFloat
    var label: String?

    @Environment(\.displayScale) private var displayScale
    @State private var picture: CGImage?

    private var key: ImageStore.Key {
        ImageStore.Key(url: url, maximumPixelSize: Int((side * max(displayScale, 1)).rounded(.up)))
    }

    var body: some View {
        ZStack {
            if let picture {
                Image(decorative: picture, scale: displayScale)
                    .resizable()
                    .frame(width: side, height: side)
                    .clipShape(.circle)
                    // The ring is what separates the badge from the art under
                    // it. Without it a dark mark on dark box art disappears.
                    .overlay { Circle().strokeBorder(Palette.canvas, lineWidth: 2) }
                    .help(label ?? "")
                    .accessibilityLabel(Text(label ?? "Publisher"))
                    .transition(.opacity)
            }
        }
        .frame(width: side, height: side)
        .task(id: key) {
            let key = key
            picture = ImageStore.shared.cached(key, bucket: .thumbnail)
            guard picture == nil else { return }
            let loaded = await ImageStore.shared.image(for: key, bucket: .thumbnail)
            guard !Task.isCancelled else { return }
            picture = loaded
        }
    }
}
