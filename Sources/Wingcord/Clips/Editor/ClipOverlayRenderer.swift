import AppKit
import CoreGraphics
import Foundation
import WingcordCore
import WingcordVoice

// MARK: - Drawing the editor's words and pictures
//
// One renderer for the preview and the export, so what the editor shows is
// what the clip gets: Discord's text overlay (heavy type, its fill, its
// stroke at None / Small / Medium / Large) and its image overlay (a PNG, JPEG
// or WebP at Small / Medium / Large, with a shadow in a colour of its own).
// Drawn for a picture of a given height; the export's compositor scales it to
// the size it settles on.

enum ClipOverlayRenderer {

    /// The height overlays are drawn for — the tallest a clip is exported at.
    static let referenceHeight: CGFloat = 1_080

    /// A text overlay as a picture, and its frame in the picture's 0…1 space.
    static func render(_ text: TextOverlay, aspect: CGFloat) -> (image: CGImage, frame: CGRect)? {
        let height = referenceHeight
        let width = height * aspect
        let words = text.text.isEmpty ? " " : text.text
        let font = NSFont.systemFont(ofSize: text.fontSize, weight: .heavy)
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(rgb: text.color),
        ]
        if text.strokeWidth != .none {
            // Negative: fill and outline both, the outline a share of the size.
            attributes[.strokeColor] = NSColor(rgb: text.strokeColor)
            attributes[.strokeWidth] = -text.strokeFraction * 100
        }
        let string = NSAttributedString(string: words, attributes: attributes)
        let bounds = string.boundingRect(
            with: CGSize(width: width * 0.9, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let pad = ceil(text.fontSize * text.strokeFraction) + 4
        let size = CGSize(width: ceil(bounds.width) + pad * 2, height: ceil(bounds.height) + pad * 2)
        guard let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        string.draw(with: CGRect(x: pad, y: pad, width: bounds.width, height: bounds.height),
                    options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { return nil }
        return (image, frame(centredAt: CGPoint(x: text.x, y: text.y), size: size, in: CGSize(width: width, height: height)))
    }

    /// An image overlay as a picture with its shadow, and its frame.
    static func render(_ overlay: ImageOverlay, assets: URL, aspect: CGFloat) -> (image: CGImage, frame: CGRect)? {
        let height = referenceHeight
        let width = height * aspect
        guard let source = NSImage(contentsOf: assets.appendingPathComponent(overlay.fileName)),
              let picture = source.cgImage(forProposedRect: nil, context: nil, hints: nil),
              picture.width > 0
        else { return nil }
        let drawnWidth = width * overlay.widthFraction
        let drawnHeight = drawnWidth * CGFloat(picture.height) / CGFloat(picture.width)
        let blur = overlay.hasShadow ? max(8, drawnWidth * 0.04) : 0
        let pad = blur * 2
        let size = CGSize(width: ceil(drawnWidth + pad * 2), height: ceil(drawnHeight + pad * 2))
        guard let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        if overlay.hasShadow {
            context.setShadow(offset: CGSize(width: 0, height: -blur / 3), blur: blur, color: NSColor(rgb: overlay.shadowColor).cgColor)
        }
        context.interpolationQuality = .high
        context.draw(picture, in: CGRect(x: pad, y: pad, width: drawnWidth, height: drawnHeight))
        guard let image = context.makeImage() else { return nil }
        return (image, frame(centredAt: CGPoint(x: overlay.x, y: overlay.y), size: size, in: CGSize(width: width, height: height)))
    }

    /// A caption line: the words centred in a dark box at the canvas's foot
    /// or head, at most nine tenths of its width.
    static func render(_ caption: Caption, style: CaptionStyle, aspect: CGFloat) -> (image: CGImage, frame: CGRect)? {
        let height = referenceHeight
        let width = height * aspect
        let font = NSFont.systemFont(ofSize: style.fontSize, weight: .semibold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let string = NSAttributedString(string: caption.text.isEmpty ? " " : caption.text, attributes: [
            .font: font,
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
        ])
        let bounds = string.boundingRect(
            with: CGSize(width: width * 0.86, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let padX = style.fontSize * 0.45
        let padY = style.fontSize * 0.22
        let size = CGSize(width: ceil(bounds.width + padX * 2), height: ceil(bounds.height + padY * 2))
        guard let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        if style.hasBackground {
            context.addPath(CGPath(
                roundedRect: CGRect(origin: .zero, size: size), cornerWidth: style.fontSize * 0.3,
                cornerHeight: style.fontSize * 0.3, transform: nil
            ))
            context.setFillColor(NSColor.black.withAlphaComponent(0.62).cgColor)
            context.fillPath()
        } else {
            context.setShadow(offset: CGSize(width: 0, height: -2), blur: style.fontSize * 0.18, color: NSColor.black.withAlphaComponent(0.85).cgColor)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        string.draw(with: CGRect(x: padX, y: padY, width: bounds.width, height: bounds.height),
                    options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { return nil }
        let margin = 0.06
        let frameHeight = size.height / height
        let y = style.placement == .bottom ? 1 - margin - frameHeight / 2 : margin + frameHeight / 2
        return (image, frame(centredAt: CGPoint(x: 0.5, y: y), size: size, in: CGSize(width: width, height: height)))
    }

    /// D15's "Burn in": each person's face, ringed, in a row at the canvas's
    /// bottom left, for each stretch they speak — the faces Discord's player
    /// lights from the same timeline.
    static func speakingFaces(manifest: ClipManifest, aspect: CGFloat) -> [RenderedOverlay] {
        let height = referenceHeight
        let width = height * aspect
        let side: CGFloat = 96
        let gap: CGFloat = 18
        var spans: [UInt64: [(Double, Double)]] = [:]
        var open: [UInt64: Double] = [:]
        for entry in manifest.timeline.sorted(by: { $0.timestampMS < $1.timestampMS }) {
            guard case .speaking(let userID, let flags) = entry.event else { continue }
            let time = Double(entry.timestampMS) / 1_000
            if flags & ClipTimeline.voiceFlag != 0 {
                if open[userID] == nil { open[userID] = time }
            } else if let start = open.removeValue(forKey: userID) {
                spans[userID, default: []].append((start, time))
            }
        }
        for (userID, start) in open { spans[userID, default: []].append((start, manifest.duration)) }

        var overlays: [RenderedOverlay] = []
        let speakers = manifest.participants.filter { spans[$0.userID] != nil }
        for (slot, person) in speakers.enumerated() {
            guard let face = faceImage(person, side: side) else { continue }
            let centre = CGPoint(
                x: (gap + side / 2 + CGFloat(slot) * (side + gap)) / width,
                y: 1 - (gap * 2 + side / 2) / height
            )
            let frame = Self.frame(centredAt: centre, size: CGSize(width: side + 12, height: side + 12), in: CGSize(width: width, height: height))
            for span in spans[person.userID] ?? [] {
                overlays.append(RenderedOverlay(image: face, frame: frame, start: span.0, end: span.1))
            }
        }
        return overlays
    }

    /// A face in a green ring — the picture this Mac already has, or the
    /// person's initials.
    private static func faceImage(_ person: ClipParticipant, side: CGFloat) -> CGImage? {
        let total = side + 12
        guard let context = CGContext(
            data: nil, width: Int(total), height: Int(total), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let ring = CGRect(x: 2, y: 2, width: total - 4, height: total - 4)
        context.setStrokeColor(NSColor(srgbRed: 0x23 / 255, green: 0xA5 / 255, blue: 0x5A / 255, alpha: 1).cgColor)
        context.setLineWidth(5)
        context.strokeEllipse(in: ring)
        let face = CGRect(x: 6, y: 6, width: side, height: side)
        context.addEllipse(in: face)
        context.clip()
        let picture = person.avatarURL.flatMap { url in
            ImageStore.shared.cached(ImageStore.Key(url: url, maximumPixelSize: 128))
                ?? ImageStore.shared.cached(ImageStore.Key(url: url, maximumPixelSize: 64))
        }
        if let picture {
            context.draw(picture, in: face)
        } else {
            context.setFillColor(NSColor(srgbRed: 0.35, green: 0.4, blue: 0.95, alpha: 1).cgColor)
            context.fill(face)
            let letters = AppModel.monogram(of: person.name)
            let font = NSFont.systemFont(ofSize: side * 0.4, weight: .semibold)
            let string = NSAttributedString(string: letters, attributes: [.font: font, .foregroundColor: NSColor.white])
            let size = string.size()
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            string.draw(at: CGPoint(x: face.midX - size.width / 2, y: face.midY - size.height / 2))
            NSGraphicsContext.restoreGraphicsState()
        }
        return context.makeImage()
    }

    private static func frame(centredAt centre: CGPoint, size: CGSize, in picture: CGSize) -> CGRect {
        let width = size.width / picture.width
        let height = size.height / picture.height
        return CGRect(x: centre.x - width / 2, y: centre.y - height / 2, width: width, height: height)
    }
}

extension NSColor {
    /// 0xRRGGBB, sRGB.
    convenience init(rgb: UInt32) {
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255, alpha: 1
        )
    }

    /// The colour as 0xRRGGBB, sRGB.
    var rgb: UInt32 {
        guard let color = usingColorSpace(.sRGB) else { return 0 }
        func channel(_ value: CGFloat) -> UInt32 { UInt32((min(1, max(0, value)) * 255).rounded()) }
        return channel(color.redComponent) << 16 | channel(color.greenComponent) << 8 | channel(color.blueComponent)
    }
}
