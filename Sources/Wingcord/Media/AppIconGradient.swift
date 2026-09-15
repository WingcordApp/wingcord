import CoreGraphics
import SwiftUI
import WingcordCore

// MARK: - The banner an app with no artwork gets
//
// **A port of Discord's own, and every part of it is read off its bundle rather
// than fitted to a screenshot.** The directory's banner component falls through
// to this when an app has neither an `embedded_cover` nor a `bot.banner`:
//
//     function eA({iconURL}) {
//       let [primary, secondary, partner] = useColors(iconURL, "transparent")
//       return <div style={{backgroundImage:
//         `linear-gradient(45deg, ${primary}, ${partner ?? secondary})`}}/>
//     }
//
// and the store behind `useColors` is the same one this app already ports for a
// profile with no `theme_colors`:
//
//     let palette = await getPalette(url)          // 5 swatches, 128px, quality 10
//     store[url] = [...palette.slice(0, 2), ...Q7(palette[0])]
//
// So the two halves were already in the tree: `ProfileThemePalette` is
// `getPalette` and `PaletteHarmony` is `Q7`. Verified byte for byte against two
// gradients Discord actually rendered — OwO's and Roll20's — in
// `PaletteHarmonyTests`.

/// The two stops, as Discord composes them.
struct AppIconGradient: Hashable, Sendable {
    var primary: Color
    var partner: Color

    /// **45°, and CSS measures it anticlockwise from the x-axis** — so the
    /// first stop is at the bottom-left corner and the second at the top-right,
    /// which is what these two unit points are.
    var fill: LinearGradient {
        LinearGradient(
            colors: [primary, partner],
            startPoint: .bottomLeading,
            endPoint: .topTrailing
        )
    }

    /// Derives one from an app's icon, or nothing where the artwork yields no
    /// palette — which is a real answer, and the caller keeps its own ground.
    static func derive(from image: CGImage) -> AppIconGradient? {
        let swatches = ProfileThemePalette.swatches(from: image)
        guard let primary = swatches.first else { return nil }
        // `partner ?? secondary`, exactly as the component reads it. `partners`
        // only comes back empty for a count of zero, so the fallback is the
        // shape of the reference rather than a path this can take.
        let partner = PaletteHarmony.partners(of: primary).first
            ?? swatches.dropFirst().first
            ?? primary
        return AppIconGradient(primary: Color(primary), partner: Color(partner))
    }
}

private extension Color {
    init(_ swatch: SIMD3<UInt8>) {
        self.init(
            .sRGB,
            red: Double(swatch.x) / 255,
            green: Double(swatch.y) / 255,
            blue: Double(swatch.z) / 255,
            opacity: 1
        )
    }
}

/// Works one out per app, once.
///
/// **Off the icon already in the image cache, at the size the palette needs.**
/// The quantiser's 128-pixel rendition is a size rung the CDN serves and
/// `ImageStore` caches, so a grid of forty-eight tiles costs forty-eight small
/// fetches it would mostly have made anyway — and each answer is kept, because
/// it cannot change while the app's icon does not.
@MainActor
@Observable
final class AppIconGradientStore {
    static let shared = AppIconGradientStore()

    private(set) var gradients: [ApplicationID: AppIconGradient] = [:]
    /// Ids already being worked out. A `LazyVGrid` runs a cell's `task` again
    /// on every scroll back into view, and without this each pass would start
    /// another decode of the same picture.
    private var inFlight: Set<ApplicationID> = []

    private init() {}

    func gradient(for id: ApplicationID) -> AppIconGradient? { gradients[id] }

    /// Idempotent: safe to call from a `.task` that re-runs, and a no-op once
    /// the answer is in.
    func resolve(_ id: ApplicationID, iconHash: String?) async {
        guard gradients[id] == nil, !inFlight.contains(id) else { return }
        // **The default asset where the app registered no icon**, because that
        // is the picture Discord draws *and* the one it quantises — an app with
        // `icon: null` gets the same blurple pair every time rather than no
        // banner at all.
        let resolved = iconHash.flatMap {
            CDN.applicationIcon(
                id: id,
                hash: $0,
                // **The palette's own rendition, not the mark's.** 128 pixels
                // and WebP are two of the three things `MedianCutQuantizer`
                // says are load-bearing: at 256 a different swatch wins.
                side: CGFloat(ProfileThemePalette.applicationPixelSize),
                scale: 1
            )
        } ?? CDN.defaultApplicationIcon
        guard let url = resolved else { return }
        inFlight.insert(id)
        defer { inFlight.remove(id) }
        let key = ImageStore.Key(url: url, maximumPixelSize: ProfileThemePalette.applicationPixelSize)
        guard let image = await ImageStore.shared.image(for: key),
              let gradient = AppIconGradient.derive(from: image)
        else { return }
        gradients[id] = gradient
    }
}
