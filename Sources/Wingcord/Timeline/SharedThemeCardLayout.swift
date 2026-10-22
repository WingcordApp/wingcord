import AppKit
import CoreGraphics
import Foundation
import WingcordCore

/// A custom theme somebody shared, laid out — Discord's theme card (`tR`, web
/// build 641803): the gradient, "Custom Theme" and its Nitro mark, "Created by"
/// with the sharer's face, and Preview. Wingcord adds Save, which keeps it in
/// Settings › Appearance (docs/CLIPS-PRESENCE.md, D25).
///
/// **The buttons' faces are decided at paint time** — previewing or not, kept
/// or not — so pressing one is a repaint, as an invite's Join is.
nonisolated struct SharedThemeCardSlot: Sendable {
    var rect: CGRect
    var theme: SharedClientTheme
    /// Who shared it, by the name the transcript gives them — what Save keeps.
    var creatorName: String
    var swatchRect: CGRect
    var title: TimelineTextBlock
    var titleOrigin: CGPoint
    var nitroRect: CGRect
    var nitro: TimelineTextBlock
    var nitroOrigin: CGPoint
    var creatorAvatarURL: URL?
    var creatorAvatarRect: CGRect
    var creator: TimelineTextBlock
    var creatorOrigin: CGPoint
    var preview: Button
    var save: Button

    struct Button: Sendable {
        var rect: CGRect
        /// Before, and after: Preview / Stop Preview, Save / Saved.
        var idle: Face
        var active: Face

        struct Face: Sendable {
            var label: TimelineTextBlock
            var labelOrigin: CGPoint
        }
    }

    var pictures: [(url: URL, rect: CGRect)] {
        creatorAvatarURL.map { [($0, creatorAvatarRect)] } ?? []
    }
}

nonisolated enum SharedThemeCardLayoutEngine {
    static let width: CGFloat = 300
    static let inset: CGFloat = 12
    static let swatchSide: CGFloat = 56
    static let swatchCorner: CGFloat = 12
    static let avatarSide: CGFloat = 20
    static let buttonHeight: CGFloat = 32
    static let buttonCorner: CGFloat = 8

    static func layout(
        _ theme: SharedClientTheme,
        creatorName: String,
        creatorAvatarURL: URL?,
        origin: CGPoint,
        availableWidth: CGFloat,
        style: MessageTextStyle
    ) -> SharedThemeCardSlot {
        let width = min(Self.width, availableWidth)
        let contentX = origin.x + inset
        let contentRight = origin.x + width - inset
        var y = origin.y + inset

        let swatchRect = CGRect(x: contentX, y: y, width: swatchSide, height: swatchSide)
        let textX = swatchRect.maxX + 12
        let textWidth = max(60, contentRight - textX)

        // Discord's own words: "Custom Theme" in heading-md/semibold, its
        // Nitro mark after it.
        let title = block("Custom Theme", font: NSFont.systemFont(ofSize: style.bodyFont.pointSize, weight: .semibold),
                          color: style.primaryColor, width: textWidth - 52, style: style, hugs: true)
        let nitro = block("NITRO", font: NSFont.systemFont(ofSize: 9, weight: .bold),
                          color: style.secondaryColor, width: 44, style: style, hugs: true)
        let creator = block("Created by \(creatorName)", font: style.metadataFont, color: style.secondaryColor,
                            width: textWidth - avatarSide - 6, style: style)
        let textHeight = title.size.height + 6 + max(avatarSide, creator.size.height)
        let titleY = swatchRect.midY - textHeight / 2
        let titleOrigin = CGPoint(x: textX, y: titleY)
        let nitroRect = CGRect(
            x: textX + title.size.width + 6, y: titleY + (title.size.height - 14) / 2,
            width: nitro.size.width + 10, height: 14
        )
        let nitroOrigin = CGPoint(x: nitroRect.minX + 5, y: nitroRect.midY - nitro.size.height / 2)
        let lineY = titleY + title.size.height + 6
        let creatorAvatarRect = CGRect(x: textX, y: lineY, width: avatarSide, height: avatarSide)
        let creatorOrigin = CGPoint(x: creatorAvatarRect.maxX + 6, y: creatorAvatarRect.midY - creator.size.height / 2)
        y = max(swatchRect.maxY, lineY + avatarSide) + 12

        // Preview, the card's own action, and Save beside it.
        let gap: CGFloat = 8
        let half = ((contentRight - contentX) - gap) / 2
        let previewRect = CGRect(x: contentX, y: y, width: half, height: buttonHeight)
        let saveRect = CGRect(x: previewRect.maxX + gap, y: y, width: half, height: buttonHeight)
        let preview = button(in: previewRect, idle: "Preview", active: "Stop Preview", prominent: true, style: style)
        let save = button(in: saveRect, idle: "Save", active: "Saved", prominent: false, style: style)
        y = previewRect.maxY + inset

        return SharedThemeCardSlot(
            rect: CGRect(x: origin.x, y: origin.y, width: width, height: y - origin.y),
            theme: theme,
            creatorName: creatorName,
            swatchRect: swatchRect,
            title: title,
            titleOrigin: titleOrigin,
            nitroRect: nitroRect,
            nitro: nitro,
            nitroOrigin: nitroOrigin,
            creatorAvatarURL: creatorAvatarURL,
            creatorAvatarRect: creatorAvatarRect,
            creator: creator,
            creatorOrigin: creatorOrigin,
            preview: preview,
            save: save
        )
    }

    private static func button(
        in rect: CGRect, idle: String, active: String, prominent: Bool, style: MessageTextStyle
    ) -> SharedThemeCardSlot.Button {
        let font = NSFont.systemFont(ofSize: style.bodyFont.pointSize, weight: .semibold)
        func face(_ words: String, onBlurple: Bool) -> SharedThemeCardSlot.Button.Face {
            let label = centred(words, font: font, color: onBlurple ? .white : style.primaryColor,
                                width: rect.width, style: style)
            return .init(label: label, labelOrigin: CGPoint(x: rect.minX, y: rect.midY - label.size.height / 2))
        }
        // Stop Preview sits on the quiet plate, so its words take the card's ink.
        return .init(rect: rect, idle: face(idle, onBlurple: prominent), active: face(active, onBlurple: false))
    }

    private static func block(
        _ text: String, font: NSFont, color: NSColor, width: CGFloat, style: MessageTextStyle, hugs: Bool = false
    ) -> TimelineTextBlock {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        return TimelineTextBlock(
            text: .plain(NSAttributedString(
                string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
            )),
            width: width, style: style, hugsText: hugs
        )
    }

    private static func centred(
        _ text: String, font: NSFont, color: NSColor, width: CGFloat, style: MessageTextStyle
    ) -> TimelineTextBlock {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        return TimelineTextBlock(
            text: .plain(NSAttributedString(
                string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
            )),
            width: width, style: style
        )
    }
}

nonisolated extension TimelineRowPainter {

    /// Discord's blurple, the card's Preview — `primary` on its button.
    static let previewFill = CGColor(srgbRed: 0x58 / 255, green: 0x65 / 255, blue: 0xF2 / 255, alpha: 1)
    static let previewFillHovered = CGColor(srgbRed: 0x47 / 255, green: 0x52 / 255, blue: 0xC4 / 255, alpha: 1)

    /// A shared theme's card.
    ///
    /// - Parameters:
    ///   - isPreviewing: this theme is the one being worn for a look.
    ///   - isSaved: the reader has kept it.
    static func drawSharedThemeCard(
        _ slot: SharedThemeCardSlot,
        offset: CGPoint,
        context: CGContext,
        isPreviewing: Bool,
        isSaved: Bool,
        hovered: CGPoint?,
        images: ImageStore,
        scale: CGFloat
    ) {
        let ink = ThemeInk.current
        let frame = slot.rect.offsetBy(dx: offset.x, dy: offset.y)
        context.addPath(CGPath(roundedRect: frame, cornerWidth: 12, cornerHeight: 12, transform: nil))
        context.setFillColor(ink.cardFill)
        context.fillPath()

        // The gradient, along its own CSS angle, in its own rounded square.
        let swatch = slot.swatchRect.offsetBy(dx: offset.x, dy: offset.y)
        let stops = slot.theme.gradientStops
        if let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: stops.map { Self.color($0) } as CFArray,
            locations: stops.indices.map { stops.count > 1 ? CGFloat($0) / CGFloat(stops.count - 1) : 0 }
        ) {
            let line = GradientAxis.endpoints(angle: slot.theme.gradientAngle, in: swatch)
            context.saveGState()
            context.addPath(CGPath(roundedRect: swatch, cornerWidth: SharedThemeCardLayoutEngine.swatchCorner,
                                   cornerHeight: SharedThemeCardLayoutEngine.swatchCorner, transform: nil))
            context.clip()
            context.drawLinearGradient(gradient, start: line.start, end: line.end,
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            context.restoreGState()
        }

        drawTextFrame(slot.title, at: themeShifted(slot.titleOrigin, offset), context: context, images: images, scale: scale)
        let nitro = slot.nitroRect.offsetBy(dx: offset.x, dy: offset.y)
        context.addPath(CGPath(roundedRect: nitro, cornerWidth: nitro.height / 2, cornerHeight: nitro.height / 2, transform: nil))
        context.setFillColor(ink.lift(0.12))
        context.fillPath()
        drawTextFrame(slot.nitro, at: themeShifted(slot.nitroOrigin, offset), context: context, images: images, scale: scale)

        let avatar = slot.creatorAvatarRect.offsetBy(dx: offset.x, dy: offset.y)
        context.saveGState()
        context.addEllipse(in: avatar)
        context.clip()
        if let url = slot.creatorAvatarURL,
           let image = images.cached(ImageStore.Key(url: url, maximumPixelSize: Int((avatar.width * scale).rounded(.up)))) {
            drawFlipped(image, in: avatar, context: context)
        } else {
            context.setFillColor(ink.surfaceRaised)
            context.fill(avatar)
        }
        context.restoreGState()
        drawTextFrame(slot.creator, at: themeShifted(slot.creatorOrigin, offset), context: context, images: images, scale: scale)

        for (button, isActive, prominent) in [(slot.preview, isPreviewing, true), (slot.save, isSaved, false)] {
            let rect = button.rect.offsetBy(dx: offset.x, dy: offset.y)
            let isHovered = hovered == button.rect.origin && !(isActive && !prominent)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: SharedThemeCardLayoutEngine.buttonCorner,
                                   cornerHeight: SharedThemeCardLayoutEngine.buttonCorner, transform: nil))
            // A preview being worn quiets its button — the action now is to stop.
            context.setFillColor(prominent && !isActive
                ? (isHovered ? previewFillHovered : previewFill)
                : ink.lift(isHovered ? 0.18 : 0.12))
            context.fillPath()
            // Saved is a state, said by its word and a plate that no longer
            // lights under the pointer — never by greying the word out.
            let face = isActive ? button.active : button.idle
            drawTextFrame(face.label, at: themeShifted(face.labelOrigin, offset), context: context, images: images, scale: scale)
        }
    }

    private static func color(_ packed: UInt32) -> CGColor {
        CGColor(
            srgbRed: CGFloat((packed >> 16) & 0xFF) / 255,
            green: CGFloat((packed >> 8) & 0xFF) / 255,
            blue: CGFloat(packed & 0xFF) / 255,
            alpha: 1
        )
    }

    private static func themeShifted(_ point: CGPoint, _ offset: CGPoint) -> CGPoint {
        CGPoint(x: point.x + offset.x, y: point.y + offset.y)
    }
}
