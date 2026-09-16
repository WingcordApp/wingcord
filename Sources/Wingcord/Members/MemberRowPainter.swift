import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import WingcordCore

/// Draws member-list rows.
///
/// **The paint order is the nameplate contract.** Every row draws its plate
/// rectangle first — artwork when there is one, a hover fill when there is not,
/// nothing when neither — and everything else draws on top of it. That order is
/// why a nameplate is a paint-time addition: the geometry already reserves the
/// layer, the text already sits above it, and the scrim that keeps the name
/// legible over arbitrary artwork is part of the same step.
nonisolated enum MemberRowPainter {

    static func drawHeader(
        title: String,
        count: Int,
        colorValue: UInt32?,
        iconURL: URL?,
        in rowFrame: CGRect,
        context: CGContext,
        style: MessageTextStyle,
        images: ImageStore,
        scale: CGFloat
    ) {
        // **The role's own capitalisation, not an upper-cased copy of it.** A
        // server names a role "Admin" or "EU Champion" and shouting it back is
        // this client deciding it knows better — and it loses information the
        // moment a role is deliberately lower case. Discord draws the name it
        // was given.
        let label = "\(title) — \(count)"
        var textX = rowFrame.minX + MemberRowGeometry.horizontalMargin
            + MemberRowGeometry.contentInset
        let side = MemberRowGeometry.sectionIconSide
        let baseline = rowFrame.minY + MemberRowGeometry.sectionSpacing + 8
        let font = NSFont.systemFont(ofSize: style.metadataFont.pointSize, weight: .semibold)

        // **Only when it is already decoded.** A painter may not start a fetch —
        // it runs inside a draw, and a heading is redrawn on every scroll — so
        // an icon that has not arrived yet simply leaves the label where it
        // would have been anyway. The row's own avatars warm the same store.
        if let iconURL,
           let icon = images.cached(
               ImageStore.Key(url: iconURL, maximumPixelSize: Int((side * scale).rounded(.up))),
               bucket: .thumbnail
           )
        {
            // Centred on the label's capitals, for the reason `capCenteredY`
            // gives: a line box is ascent plus descent, and an all-caps-ish
            // heading has no descenders to fill the space under it.
            let top = baseline + font.ascender - font.capHeight / 2 - side / 2
            context.saveGState()
            context.draw(icon, in: CGRect(x: textX, y: top, width: side, height: side))
            context.restoreGState()
            textX += side + 5
        }

        TimelineRowPainter.drawText(
            label,
            font: font,
            // A hoisted role's heading takes the role's colour, which is how the
            // list says *why* these people are grouped. The synthetic Online and
            // Offline groups have no colour and take the quiet default.
            color: colorValue.map { NSColor(Color(hex: $0)) } ?? style.tertiaryColor,
            at: CGPoint(x: textX, y: baseline),
            maxWidth: rowFrame.maxX - MemberRowGeometry.horizontalMargin - textX,
            context: context
        )
    }

    /// - Parameter nameFace: the styled face this person's name is set in,
    ///   already resolved. **Resolved by the caller, not looked up here** — the
    ///   registry is main-actor state and this painter is deliberately
    ///   `nonisolated` so a draw cannot reach into the model, which is the rule
    ///   `INVARIANTS.md` §4.5 is written around. Nil is the ordinary case and
    ///   means the app's own face.
    /// - Parameter plateFrame: one frame of the plate's moving form, when this
    ///   row is the one playing it. **Resolved by the caller** for the same
    ///   reason `nameFace` is: the filmstrip lives behind a main-actor clock and
    ///   this painter is deliberately `nonisolated`. Nil is every row but one,
    ///   and means the still.
    static func drawMember(
        _ entry: MemberEntry,
        in rowFrame: CGRect,
        context: CGContext,
        style: MessageTextStyle,
        isHovered: Bool,
        images: ImageStore,
        scale: CGFloat,
        nameFace: NSFont? = nil,
        plateFrame: CGImage? = nil,
        /// One frame of this person's moving avatar, or nil for the still —
        /// which is every row but the one under the pointer. Resolved by the
        /// caller for the same reason `plateFrame` is.
        avatarFrame: CGImage? = nil,
        /// One frame of their moving decoration, same rule.
        decorationFrame: CGImage? = nil,
        /// Where in the typing animation's cycle this row is, or nil when they
        /// are not typing — which is every row, nearly always.
        typingPhase: CGFloat? = nil,
        /// Where an enhanced role's ramp has travelled to, or nil for a name
        /// that is not animating — which is every row but the hovered one.
        gradientPhase: CGFloat? = nil
    ) {
        let plate = MemberRowGeometry.plateRect(in: rowFrame)
        let plateShape = CGPath(
            roundedRect: plate,
            cornerWidth: Radius.row,
            cornerHeight: Radius.row,
            transform: nil
        )

        // 1. The plate layer.
        drawPlate(
            entry,
            shape: plateShape,
            rect: plate,
            context: context,
            isHovered: isHovered,
            images: images,
            scale: scale,
            plateFrame: plateFrame
        )

        // 2. Avatar and presence.
        let avatar = MemberRowGeometry.avatarRect(in: rowFrame)
        drawAvatar(
            entry,
            in: avatar,
            context: context,
            style: style,
            images: images,
            scale: scale,
            avatarFrame: avatarFrame,
            decorationFrame: decorationFrame,
            typingPhase: entry.isTyping ? typingPhase : nil
        )

        // 3. Name, tag chip, activity.
        let textX = MemberRowGeometry.textOriginX(in: rowFrame)
        let available = plate.maxX - textX - MemberRowGeometry.contentInset
        let hasSubtitle = entry.subtitle != nil
        let nameY = hasSubtitle ? plate.midY - 15 : plate.midY - 8

        // Room for whatever chip follows the name, reserved before the name is
        // drawn so the name truncates to leave space rather than colliding.
        var chipLabel: String?
        var chipFill: NSColor?
        var chipBadge: URL?
        if let tag = entry.tag {
            chipLabel = tag
            chipBadge = entry.tagBadgeURL
        } else if entry.isBot {
            chipLabel = "APP"
            chipFill = NSColor.controlAccentColor
        }

        var chipWidth: CGFloat = 0
        if let chipLabel {
            chipWidth = MemberRowGeometry.tagChipWidth(
                textWidth: TimelineLayoutEngine.measure(
                    chipLabel, font: MemberRowGeometry.tagChipFont
                ),
                hasBadge: chipBadge != nil
            )
        }
        let reserved = chipWidth > 0 ? chipWidth + MemberRowGeometry.tagChipGap : 0
        let nameWidth = max(20, available - reserved)

        // **The chip follows the DRAWN text, not the slot.** `drawText` returns
        // the width it actually painted; measuring the full name and clamping it
        // to the available width instead places the chip at the end of the slot,
        // which is a visible gap on every truncated name and on nothing else.
        // **The face carries into the roster; the colour does not.** Discord's
        // own dialog says colours and effects do not appear in servers, and a
        // role colour a server chose has to beat a colour its owner did — so a
        // styled name here is the same ink as any other, set in their face.
        // The effect itself plays on hover, over this row rather than in it.
        let nameFont = nameFace ?? style.bodyFont
        let drawnName = TimelineRowPainter.drawText(
            entry.name,
            font: nameFont,
            color: entry.colorValue.map { NSColor(Color(hex: $0)) }
                ?? (entry.status == .offline ? style.tertiaryColor : style.primaryColor),
            at: CGPoint(x: textX, y: nameY),
            maxWidth: nameWidth,
            tracking: (entry.displayNameFont?.letterSpacing ?? 0) * style.bodyFont.pointSize,
            // **A server's enhanced role beats the app's ink, and only here.**
            // The note above is about a person's own display-name STYLE, which
            // a server deliberately suppresses; this is the server's own choice
            // about one of its roles, so it is drawn.
            gradient: entry.gradient.map { $0.map { NSColor(Color(hex: $0)) } },
            gradientPhase: gradientPhase,
            context: context
        )

        if let chipLabel {
            // **Centred on the name's capitals, not on its line box.** A line
            // box is ascent plus descent, and a chip centred on that sits
            // visibly low beside a name that has no descenders in it — which,
            // for the majority of names, is what the eye compares it against.
            let capCenter = nameY + style.bodyFont.ascender - style.bodyFont.capHeight / 2
            drawTagChip(
                chipLabel,
                in: CGRect(
                    x: textX + drawnName + MemberRowGeometry.tagChipGap,
                    y: (capCenter - MemberRowGeometry.tagChipHeight / 2).rounded(),
                    width: chipWidth,
                    height: MemberRowGeometry.tagChipHeight
                ),
                context: context,
                style: style,
                fill: chipFill,
                badge: chipBadge,
                images: images,
                scale: scale
            )
        }

        // The owner's crown, after the name and after whatever chip follows it.
        //
        // A glyph rather than a chip: the tag and the APP mark are things a
        // person *chose*, and a crown is a fact about the conversation. Drawing
        // it as a third capsule would put it in the same category as the other
        // two.
        if entry.isOwner {
            let trailing = textX + drawnName
                + (chipWidth > 0 ? chipWidth + MemberRowGeometry.tagChipGap : 0)
            let capCenter = nameY + style.bodyFont.ascender - style.bodyFont.capHeight / 2
            let side = MemberRowGeometry.crownSide
            let crown = CGRect(
                x: trailing + MemberRowGeometry.tagChipGap,
                y: (capCenter - side / 2).rounded(),
                width: side,
                height: side
            )
            if crown.maxX <= plate.maxX - MemberRowGeometry.contentInset {
                TimelineRowPainter.drawSymbol(
                    "crown.fill",
                    tint: NSColor(Palette.presenceIdle),
                    in: crown,
                    context: context
                )
            }
        }

        if let subtitle = entry.subtitle {
            TimelineRowPainter.drawText(
                subtitle,
                font: style.metadataFont,
                color: style.tertiaryColor,
                at: CGPoint(x: textX, y: plate.midY + 2),
                maxWidth: max(20, available),
                context: context
            )
        }

        // Offline members are dimmed as a whole rather than by picking a paler
        // colour for each element, which is one operation instead of five and
        // keeps role colours recognisable while still reading as offline.
        if entry.status == .offline {
            context.saveGState()
            context.addPath(plateShape)
            context.clip()
            context.setFillColor(NSColor.black.withAlphaComponent(0.35).cgColor)
            context.setBlendMode(.destinationOut)
            context.fill(plate)
            context.restoreGState()
        }
    }

    // MARK: Plate

    // **Built once, never per row.** A `CGGradient` is an allocation plus a
    // colour-space resolve, and a plate draws two of them; the scrim used to be
    // constructed inside the draw, so a roster of forty plated rows repainting
    // on every pointer move was building forty of it a frame for a value that
    // cannot change.
    //
    // The palette washes below are the reader's *content* — twelve fixed hues
    // Discord sells — so they are `nonisolated(unsafe)` statics for the same
    // reason `MemberRowGeometry.tagChipFont` is: immutable once created, never
    // written after first use, and `static let` initialisation is thread-safe.
    //
    // The **scrim** is not one of them. It is the theme's own surface colour and
    // has to be rebuilt when the theme changes, so it lives on `ThemeInk` beside
    // every other themed value a painter draws with — a static here was black,
    // which is a hole in whatever colour the reader chose.

    /// One wash per palette, keyed so a draw is a dictionary lookup.
    ///
    /// Twelve at most, and only those with a colour — `.none` is a real answer
    /// and gets no entry, so a plate that asked for no wash cannot be given one
    /// by a fallback.
    /// What erases the artwork's leading half.
    ///
    /// Opaque at the leading edge and gone by the time the strip's own pixels
    /// begin, so a name always sits on the row's background rather than on a
    /// picture. It is drawn with `destinationOut`, so only the *alpha* matters —
    /// the colour is black because a fully-opaque something is what erases, and
    /// which something is irrelevant.
    private nonisolated(unsafe) static let plateFade: CGGradient? = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(gray: 0, alpha: 1),
            CGColor(gray: 0, alpha: 0.75),
            CGColor(gray: 0, alpha: 0),
        ] as CFArray,
        locations: [0, 0.22, 0.62]
    )

    private nonisolated(unsafe) static let plateWashes: [NameplatePalette: CGGradient] = {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        var table: [NameplatePalette: CGGradient] = [:]
        table.reserveCapacity(NameplatePalette.allCases.count)
        for palette in NameplatePalette.allCases {
            guard let value = palette.colorValue else { continue }
            // Built as `CGColor` components rather than through
            // `NSColor(Color(hex:))`: that bridge can hand back a catalog
            // colour, and `withAlphaComponent` on one of those is not the
            // straightforward operation it looks like.
            let red = CGFloat((value >> 16) & 0xFF) / 255
            let green = CGFloat((value >> 8) & 0xFF) / 255
            let blue = CGFloat(value & 0xFF) / 255
            func tint(_ alpha: CGFloat) -> CGColor {
                CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
            }
            guard let gradient = CGGradient(
                colorsSpace: space,
                // Clear at the leading edge, where the name is, and strongest
                // under the artwork. Kept in the same register as
                // `Palette.hoverFill` and `Palette.selectionFill` — a hue at
                // low alpha over near-black reads far weaker than white does,
                // which is why the far end is above the selection pill's 0.15
                // and still reads as a wash rather than as paint.
                colors: [tint(0), tint(0.08), tint(0.24)] as CFArray,
                locations: [0, 0.5, 1]
            ) else { continue }
            table[palette] = gradient
        }
        return table
    }()

    private static func drawPlate(
        _ entry: MemberEntry,
        shape: CGPath,
        rect: CGRect,
        context: CGContext,
        isHovered: Bool,
        images: ImageStore,
        scale: CGFloat,
        plateFrame: CGImage?
    ) {
        // **The moving frame stands in for the still, in the same rectangle.**
        // Everything below — the wash, the erasing fade, the clip — is one
        // treatment applied to whichever picture the row has, so a plate cannot
        // look like two different objects depending on whether it is moving.
        //
        // `??` rather than a resolved pair, so the row that IS moving never
        // pays for the cache lookup it is not going to use.
        let image = plateFrame ?? entry.nameplateURL.flatMap { url in
            images.cached(
                ImageStore.Key(
                    url: url,
                    maximumPixelSize: Int(
                        (MemberRowGeometry.nameplateArtWidth * scale).rounded(.up)
                    )
                ),
                bucket: .artwork
            )
        }
        if let image {
            // One clip for all three layers. The plate used to save, clip, draw
            // and restore twice over, which is four state operations a row for
            // the same region.
            context.saveGState()
            context.addPath(shape)
            context.clip()

            // 1. The palette's wash, underneath everything.
            //
            // **A nameplate's artwork only covers its trailing third.**
            // Measured on the real asset: Dark Roses is a 672x126 strip whose
            // left two thirds are fully transparent. Drawn alone, that reads as
            // a picture floating beside somebody's name rather than as a plate
            // behind it, and the wash is what closes the gap between the
            // scrim's fade-out and the artwork's first pixels.
            if let wash = plateWashes[entry.nameplatePalette] {
                context.drawLinearGradient(
                    wash,
                    start: CGPoint(x: rect.minX, y: rect.midY),
                    end: CGPoint(x: rect.maxX, y: rect.midY),
                    options: []
                )
            }

            // 2. The artwork, FADED OUT toward the leading edge.
            //
            // **The fade erases the picture; it does not paint over it.** This
            // used to be a scrim — a wash laid on top, opaque under the name and
            // clear over the roses — and a scrim is a *colour*, so it can only
            // ever be the right one by accident. Black left a hole in whatever
            // theme the reader chose; the theme's own surface left a lighter
            // rectangle, because the roster's ground is the canvas under a
            // recess and not the surface. Either way the plate read as a box
            // sitting on the list rather than as artwork emerging out of it.
            //
            // Erasing has no colour to be wrong about. The strip is drawn into a
            // transparency layer and a `destinationOut` ramp takes its leading
            // half away, so what shows through is exactly the row's own
            // background — whatever that happens to be — and the picture fades
            // into it instead of stopping against a plate.
            //
            // Fit to the plate's HEIGHT and hung off its trailing edge — see
            // `MemberRowGeometry.nameplateArtRect`, which carries the
            // measurement that settled the rule. **Not aspect-fill**: fill takes
            // whichever of the two fits is larger, which lands on the width for
            // a wide plate and stretches the strip vertically.
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            TimelineRowPainter.drawFlipped(
                image,
                in: MemberRowGeometry.nameplateArtRect(
                    in: rect,
                    imagePixelSize: CGSize(width: image.width, height: image.height)
                ),
                context: context
            )
            if let fade = plateFade {
                context.setBlendMode(.destinationOut)
                context.drawLinearGradient(
                    fade,
                    start: CGPoint(x: rect.minX, y: rect.midY),
                    end: CGPoint(x: rect.maxX, y: rect.midY),
                    options: []
                )
                context.setBlendMode(.normal)
            }
            context.endTransparencyLayer()

            if isHovered {
                context.setFillColor(NSColor.white.withAlphaComponent(0.06).cgColor)
                context.fill(rect)
            }
            context.restoreGState()
            return
        }

        guard isHovered else { return }
        context.addPath(shape)
        context.setFillColor(ThemeInk.current.hoverFill)
        context.fillPath()
    }

    // MARK: Avatar

    /// The face, its decoration and its presence dot.
    ///
    /// **Three layers in one order, and the order is the whole of it**: the
    /// face is clipped to its circle, the decoration draws *outside* that clip
    /// — see `TimelineRowPainter.decorationRect` — and the dot goes over both.
    /// Drawing the decoration inside the clip loses the ears, the halo and the
    /// hat brim, which is to say everything that makes one recognisable.
    private static func drawAvatar(
        _ entry: MemberEntry,
        in frame: CGRect,
        context: CGContext,
        style: MessageTextStyle,
        images: ImageStore,
        scale: CGFloat,
        avatarFrame: CGImage? = nil,
        decorationFrame: CGImage? = nil,
        typingPhase: CGFloat? = nil
    ) {
        context.saveGState()
        context.addEllipse(in: frame)
        context.clip()
        // The moving face where this is the row playing one, the decoded still
        // everywhere else. Both are drawn through the same flip.
        if let image = avatarFrame ?? entry.avatarURL.flatMap({ url in
            images.cached(ImageStore.Key(
                url: url,
                maximumPixelSize: Int((frame.width * scale).rounded(.up))
            ))
        }) {
            TimelineRowPainter.drawFlipped(image, in: frame, context: context)
            context.restoreGState()
        } else {
            context.setFillColor(ThemeInk.current.surfaceRaised)
            context.fill(frame)
            context.restoreGState()
            let font = NSFont.systemFont(ofSize: frame.width * 0.42, weight: .semibold)
            TimelineRowPainter.drawText(
                entry.monogram,
                font: font,
                color: style.secondaryColor,
                at: CGPoint(
                    x: frame.minX,
                    y: TimelineRowPainter.capCenteredY(of: font, in: frame)
                ),
                maxWidth: frame.width,
                alignment: .center,
                context: context
            )
        }

        // **After the clip is gone.** A decoration is drawn around the face at
        // 1.2x, so it is the one thing on this row that must not be inside the
        // ellipse above — and it is drawn before the dot, which Discord puts
        // over everything.
        TimelineRowPainter.drawDecoration(
            decorationFrame ?? decorationStill(entry, around: frame, images: images, scale: scale),
            around: frame,
            context: context
        )

        // **The typing pill REPLACES the presence dot.** Discord swaps the two
        // rather than stacking them, and it has to: they share the same corner,
        // and a pill drawn over a dot is a dot poking out of its end.
        if let typingPhase {
            drawTypingPill(on: frame, phase: typingPhase, context: context)
        } else {
            drawPresenceDot(entry.status, on: frame, context: context)
        }
    }

    /// Three dots in a pill, where the presence dot would be.
    ///
    /// **The dots rise and fall in sequence** — a third of a cycle apart, which
    /// is the stagger every typing indicator uses and the one that reads as
    /// "someone is mid-sentence" rather than as a loading spinner. The phase is
    /// resolved by the caller from the shared clock, for the same reason
    /// `plateFrame` and `gradientPhase` are: this painter is `nonisolated` and
    /// may not reach a main-actor singleton from inside a draw.
    private static func drawTypingPill(
        on avatarFrame: CGRect,
        phase: CGFloat,
        context: CGContext
    ) {
        let height: CGFloat = 11
        let width: CGFloat = 20
        let pill = CGRect(
            x: avatarFrame.maxX - width + 2,
            y: avatarFrame.maxY - height + 2,
            width: width,
            height: height
        )
        // The same cut-out the presence dot takes, so the pill reads as a hole
        // in the avatar rather than a badge sitting on it.
        let ring = pill.insetBy(dx: -2, dy: -2)
        context.setFillColor(NSColor.windowBackgroundColor.cgColor)
        context.addPath(CGPath(
            roundedRect: ring,
            cornerWidth: ring.height / 2,
            cornerHeight: ring.height / 2,
            transform: nil
        ))
        context.fillPath()

        context.setFillColor(ThemeInk.current.typingPill)
        context.addPath(CGPath(
            roundedRect: pill,
            cornerWidth: pill.height / 2,
            cornerHeight: pill.height / 2,
            transform: nil
        ))
        context.fillPath()

        let dotSide: CGFloat = 3
        let gap: CGFloat = 1.5
        let run = dotSide * 3 + gap * 2
        var x = pill.midX - run / 2
        for index in 0..<3 {
            // A third of a cycle apart, and the rise is a raised cosine so the
            // dot eases at both ends instead of ticking between two positions.
            let local = (phase + CGFloat(index) / 3).truncatingRemainder(dividingBy: 1)
            let lift = (1 - cos(local * 2 * .pi)) / 2
            let box = CGRect(
                x: x,
                y: pill.midY - dotSide / 2 - lift * 1.5,
                width: dotSide,
                height: dotSide
            )
            context.setFillColor(NSColor.white.withAlphaComponent(0.55 + lift * 0.45).cgColor)
            context.fillEllipse(in: box)
            x += dotSide + gap
        }
    }

    /// The decoration's first frame, once anything has decoded it.
    ///
    /// **Only a peek.** A painter may not start a fetch — it runs inside a draw
    /// and a roster is repainted on every scroll tick — so an asset nobody
    /// prefetches is an asset that never arrives, which is the trap
    /// `INVARIANTS.md` §2 names and exactly what kept every decoration in this
    /// list invisible: `MemberEntry.decorationURL` has been decoded all along
    /// and no surface asked for the bytes. The key must equal the prefetcher's,
    /// or the picture lands in a slot this never looks in.
    private static func decorationStill(
        _ entry: MemberEntry,
        around frame: CGRect,
        images: ImageStore,
        scale: CGFloat
    ) -> CGImage? {
        guard let url = entry.decorationURL else { return nil }
        let side = TimelineRowPainter.decorationRect(around: frame).width
        return images.cached(
            ImageStore.Key(url: url, maximumPixelSize: Int((side * scale).rounded(.up))),
            bucket: .thumbnail
        )
    }

    /// The presence dot.
    ///
    /// Each state has a *shape* as well as a colour — a filled disc, a crescent,
    /// a bar, a ring. Hue alone is the first thing a colour-blind reader loses,
    /// and online-versus-idle differ by nothing else.
    private static func drawPresenceDot(
        _ status: PresenceStatus,
        on avatarFrame: CGRect,
        context: CGContext
    ) {
        let side: CGFloat = 11
        let dot = CGRect(
            x: avatarFrame.maxX - side + 2,
            y: avatarFrame.maxY - side + 2,
            width: side,
            height: side
        )
        let ring = dot.insetBy(dx: -2, dy: -2)
        context.setFillColor(NSColor.windowBackgroundColor.cgColor)
        context.fillEllipse(in: ring)

        let tint = NSColor(status.tint)
        switch status {
        case .online:
            context.setFillColor(tint.cgColor)
            context.fillEllipse(in: dot)
        case .idle:
            context.setFillColor(tint.cgColor)
            context.fillEllipse(in: dot)
            context.setFillColor(NSColor.windowBackgroundColor.cgColor)
            context.fillEllipse(in: dot.offsetBy(dx: -2.5, dy: -2.5).insetBy(dx: 1.6, dy: 1.6))
        case .doNotDisturb:
            context.setFillColor(tint.cgColor)
            context.fillEllipse(in: dot)
            context.setFillColor(NSColor.windowBackgroundColor.cgColor)
            context.fill(CGRect(
                x: dot.minX + 2, y: dot.midY - 1.1,
                width: dot.width - 4, height: 2.2
            ))
        case .offline, .invisible:
            context.setStrokeColor(tint.cgColor)
            context.setLineWidth(2.6)
            context.strokeEllipse(in: dot.insetBy(dx: 1.3, dy: 1.3))
        }
    }

    /// A clan tag or an APP badge.
    ///
    /// A clan tag carries the guild's **badge image** beside its letters — that
    /// is what a tag IS on Discord, and drawing only the letters loses the half
    /// people recognise. The badge comes out of the same cache as every other
    /// picture, at the same key `MemberListView` prefetches it under; a key that
    /// disagrees by one pixel is a badge that is fetched and then never found.
    ///
    /// The frame arrives already sized by `MemberRowGeometry.tagChipWidth`, so
    /// the padding here and the width reserved for the chip cannot disagree —
    /// and the contents are laid out from the leading padding rightwards, which
    /// leaves the trailing padding equal to it by construction.
    private static func drawTagChip(
        _ label: String,
        in frame: CGRect,
        context: CGContext,
        style: MessageTextStyle,
        fill: NSColor? = nil,
        badge: URL? = nil,
        images: ImageStore? = nil,
        scale: CGFloat = 2
    ) {
        let corner = MemberRowGeometry.tagChipHeight / 2
        context.addPath(CGPath(
            roundedRect: frame, cornerWidth: corner, cornerHeight: corner, transform: nil
        ))
        context.setFillColor((fill ?? NSColor.white.withAlphaComponent(0.12)).cgColor)
        context.fillPath()

        var textX = frame.minX + MemberRowGeometry.tagChipPadding
        if let badge, let images {
            let side = MemberRowGeometry.tagBadgeSide
            let glyph = CGRect(
                x: textX,
                y: (frame.midY - side / 2).rounded(),
                width: side,
                height: side
            )
            if let image = images.cached(ImageStore.Key(
                url: badge,
                maximumPixelSize: Int((side * scale).rounded(.up))
            )) {
                context.saveGState()
                context.translateBy(x: 0, y: glyph.midY)
                context.scaleBy(x: 1, y: -1)
                context.translateBy(x: 0, y: -glyph.midY)
                context.draw(image, in: glyph)
                context.restoreGState()
            }
            textX = glyph.maxX + MemberRowGeometry.tagBadgeGap
        }

        let font = MemberRowGeometry.tagChipFont
        TimelineRowPainter.drawText(
            label,
            font: font,
            color: fill == nil ? style.secondaryColor : .white,
            at: CGPoint(x: textX, y: TimelineRowPainter.capCenteredY(of: font, in: frame)),
            maxWidth: frame.maxX - MemberRowGeometry.tagChipPadding - textX,
            context: context
        )
    }
}
