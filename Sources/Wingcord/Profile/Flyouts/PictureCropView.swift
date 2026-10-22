import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import WingcordCore

/// "Edit Image" — a picked avatar or banner, dragged and zoomed into its shape
/// before it goes into the draft. Discord's own upload step; without it a
/// picture of the wrong shape was cropped wherever Discord's server chose.
///
/// The arithmetic is `PictureCrop`'s; this only draws it. **Skip** sends the
/// picture as it is.
struct PictureCropView: View {
    var shape: PictureCrop.Shape
    /// The first frame, to draw.
    var preview: CGImage
    var apply: (PictureCrop) -> Void
    var skip: () -> Void

    @Environment(\.motion) private var motion
    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var dragOrigin: CGSize?

    private var viewport: CGSize {
        switch shape {
        case .avatar: CGSize(width: 240, height: 240)
        case .banner: CGSize(width: 308, height: (308 / PictureCrop.Shape.banner.aspect).rounded())
        }
    }

    private var crop: PictureCrop {
        PictureCrop(
            shape: shape,
            imageSize: CGSize(width: preview.width, height: preview.height),
            viewport: viewport,
            zoom: zoom,
            offset: offset
        )
    }

    var body: some View {
        VStack(spacing: Spacing.snug) {
            canvas
            zoomRow
            HStack(spacing: Spacing.base) {
                Button("Reset") {
                    zoom = 1
                    offset = .zero
                    Haptics.tick()
                }
                .buttonStyle(.glass)
                .disabled(zoom == 1 && offset == .zero)
                Spacer(minLength: 0)
                Button("Skip", action: skip)
                    .buttonStyle(.glass)
                    .help("Use the picture as it is")
                Button("Apply") { apply(crop) }
                    .buttonStyle(.glassProminent)
            }
            .buttonBorderShape(.capsule)
        }
    }

    private var canvas: some View {
        let current = crop
        return Image(decorative: preview, scale: 1)
            .resizable()
            .interpolation(.high)
            .frame(width: current.drawnSize.width, height: current.drawnSize.height)
            .offset(current.offset)
            .frame(width: viewport.width, height: viewport.height)
            .clipped()
            .overlay {
                // The cut-out's own outline: a circle for an avatar, Discord's
                // shape, with the corners shaded so the reader sees what goes.
                if shape == .avatar {
                    Path { path in
                        let rect = CGRect(origin: .zero, size: viewport)
                        path.addRect(rect)
                        path.addEllipse(in: rect)
                    }
                    .fill(.black.opacity(0.5), style: FillStyle(eoFill: true))
                    Circle().strokeBorder(.white.opacity(0.85), lineWidth: 2)
                } else {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(.white.opacity(0.85), lineWidth: 2)
                }
            }
            .clipShape(.rect(cornerRadius: shape == .avatar ? 12 : 6, style: .continuous))
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let origin = dragOrigin ?? offset
                        if dragOrigin == nil { dragOrigin = origin }
                        offset = crop.clamped(CGSize(
                            width: origin.width + value.translation.width,
                            height: origin.height + value.translation.height
                        ))
                    }
                    .onEnded { _ in dragOrigin = nil }
            )
            .accessibilityElement()
            .accessibilityLabel(Text("Crop area"))
            .accessibilityHint(Text("Drag to move the picture."))
    }

    private var zoomRow: some View {
        HStack(spacing: Spacing.base) {
            Image(systemName: "photo")
                .font(.system(size: 11))
                .foregroundStyle(InkColor.secondary)
            Slider(
                value: Binding(
                    get: { zoom },
                    set: { proposed in
                        // A notch at 1×, felt — the picture back to filling.
                        let snapped = abs(proposed - 1) < 0.04 ? 1 : proposed
                        if snapped == 1, zoom != 1 { Haptics.tick() }
                        zoom = snapped
                        offset = crop.clamped(offset)
                    }
                ),
                in: 1...PictureCrop.maximumZoom
            )
            .accessibilityLabel(Text("Zoom"))
            Image(systemName: "photo")
                .font(.system(size: 17))
                .foregroundStyle(InkColor.secondary)
        }
    }
}

extension PictureFile {
    /// The first frame, for drawing the crop.
    static func firstFrame(_ image: ImageData) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(image.bytes as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// The picture cut to `crop` — a PNG for a still, a GIF of every frame,
    /// each with its own delay, for a moving one.
    static func cropped(_ image: ImageData, to crop: PictureCrop) -> ImageData? {
        guard let source = CGImageSourceCreateWithData(image.bytes as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        let rect = crop.cropRect
        let size = crop.outputSize
        let output = NSMutableData()
        let type = count > 1 ? UTType.gif : UTType.png
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, count, nil)
        else { return nil }
        if count > 1 {
            let loop = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary
            CGImageDestinationSetProperties(destination, loop)
        }
        for index in 0..<count {
            guard let frame = CGImageSourceCreateImageAtIndex(source, index, nil),
                  let cut = frame.cropping(to: rect),
                  let scaled = scale(cut, to: size)
            else { return nil }
            var properties: CFDictionary?
            if count > 1 {
                let delay = frameDelay(source, at: index)
                properties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary
            }
            CGImageDestinationAddImage(destination, scaled, properties)
        }
        guard CGImageDestinationFinalize(destination) else { return nil }
        return count > 1 ? .gif(output as Data) : .png(output as Data)
    }

    private static func scale(_ image: CGImage, to size: CGSize) -> CGImage? {
        let width = Int(size.width), height = Int(size.height)
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// A frame's delay, from whichever dictionary the format keeps it in.
    private static func frameDelay(_ source: CGImageSource, at index: Int) -> Double {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        let dictionaries: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
        ]
        for (key, unclamped, clamped) in dictionaries {
            guard let entry = properties[key] as? [CFString: Any] else { continue }
            if let value = entry[unclamped] as? Double, value > 0 { return value }
            if let value = entry[clamped] as? Double, value > 0 { return value }
        }
        return 0.1
    }
}

extension PictureFile {
    /// A still as PNG bytes.
    static func encodePNG(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}
