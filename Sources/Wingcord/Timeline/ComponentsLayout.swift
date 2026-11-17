import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import WingcordCore

/// Lays out a **Components V2** message — one built entirely out of components
/// rather than out of `content` and `embeds`.
///
/// **It produces the same two things an embed does**, and that is the whole
/// design: a container is a card with an accent rule and stacked content, which
/// is exactly what `EmbedSlot` already describes, and a row of buttons is
/// exactly what `ComponentSlot` already describes. So the painter needs no new
/// cases, the prefetch needs no new kinds, and hit testing already covers both.
///
/// A container's descendants are flattened into that one slot with absolute
/// origins rather than kept as a tree, for the reason the transcript is flat at
/// every other level: a nested value cannot be walked in a draw loop without the
/// loop learning the tree's shape, and the shape is decided here exactly once.
nonisolated enum ComponentsLayoutEngine {

    /// Everything one message's tree turns into.
    struct Output: Sendable {
        var cards: [EmbedSlot] = []
        var controls: [ComponentSlot] = []
        /// Where the next thing after the tree starts.
        var bottom: CGFloat = 0
    }

    /// Between two top-level nodes.
    static let blockGap: CGFloat = 8
    /// A separator's own height, small and large.
    static let separatorSmall: CGFloat = 8
    static let separatorLarge: CGFloat = 16

    struct Context: Sendable {
        var style: MessageTextStyle
        var mentions: MentionContext
        var parser: MarkdownParser
    }

    /// Lays a whole tree out from `origin`, inside `width`.
    static func layout(
        _ nodes: [DisplayComponent],
        origin: CGPoint,
        width: CGFloat,
        context: Context
    ) -> Output {
        var output = Output(bottom: origin.y)
        var y = origin.y

        for node in nodes {
            switch node {
            case .container(let accent, let children):
                let card = container(
                    accent: accent,
                    children: children,
                    origin: CGPoint(x: origin.x, y: y),
                    width: width,
                    context: context,
                    controls: &output.controls
                )
                output.cards.append(card)
                y = card.rect.maxY + blockGap

            case .row(let row):
                var controls: [ComponentSlot] = []
                y = TimelineLayoutEngine.layoutComponentRows(
                    [row],
                    contentX: origin.x,
                    y: y,
                    width: width,
                    style: context.style,
                    into: &controls
                )
                output.controls.append(contentsOf: controls)
                y += blockGap

            case .separator(_, let isLarge):
                // A loose separator between cards is space, never a rule: the
                // cards already have edges, and a line between two bordered
                // boxes is a third edge in the same gap.
                y += isLarge ? separatorLarge : separatorSmall

            default:
                // Loose prose, a section or a gallery: content with no ground
                // behind it, drawn exactly where it stands.
                var loose = EmbedSlot(
                    rect: CGRect(x: origin.x, y: y, width: width, height: 0),
                    accent: nil,
                    drawsCard: false,
                    texts: [],
                    images: []
                )
                let bottom = place(
                    node,
                    origin: CGPoint(x: origin.x, y: y),
                    width: width,
                    context: context,
                    into: &loose,
                    controls: &output.controls
                )
                loose.rect.size.height = bottom - y
                if !loose.texts.isEmpty || !loose.images.isEmpty {
                    output.cards.append(loose)
                }
                y = bottom + blockGap
            }
        }

        output.bottom = max(origin.y, y - blockGap)
        return output
    }

    // MARK: Containers

    private static func container(
        accent: UInt32?,
        children: [DisplayComponent],
        origin: CGPoint,
        width: CGFloat,
        context: Context,
        controls: inout [ComponentSlot]
    ) -> EmbedSlot {
        let padding = EmbedLayoutEngine.padding
        let rule = EmbedLayoutEngine.ruleWidth
        let contentX = origin.x + rule + padding
        let contentWidth = max(40, width - rule - padding * 2)

        var card = EmbedSlot(
            rect: CGRect(x: origin.x, y: origin.y, width: width, height: 0),
            accent: accent.flatMap { NSColor(Color(hex: $0)) },
            texts: [],
            images: []
        )

        var y = origin.y + padding
        for (index, child) in children.enumerated() {
            if case .separator(let isDivider, let isLarge) = child {
                // **Inside a card a separator IS a rule**, which is the one
                // place it means something: it divides one region of a ground
                // from the next, and there are no edges in here to compete with.
                let gap = isLarge ? separatorLarge : separatorSmall
                y += gap / 2
                if isDivider {
                    card.rules.append(CGRect(
                        x: contentX, y: y.rounded(), width: contentWidth, height: 1
                    ))
                    y += 1
                }
                y += gap / 2
                continue
            }
            if index > 0 { y += blockGap }
            y = place(
                child,
                origin: CGPoint(x: contentX, y: y),
                width: contentWidth,
                context: context,
                into: &card,
                controls: &controls
            )
        }

        card.rect.size.height = max(padding * 2, y - origin.y + padding)
        return card
    }

    // MARK: One node

    /// Places one node into `card` and answers the y it ended at.
    private static func place(
        _ node: DisplayComponent,
        origin: CGPoint,
        width: CGFloat,
        context: Context,
        into card: inout EmbedSlot,
        controls: inout [ComponentSlot]
    ) -> CGFloat {
        switch node {
        case .text(let markdown):
            let block = EmbedLayoutEngine.markdown(
                markdown, width: width, context: context
            )
            card.texts.append(EmbedText(block: block, origin: origin))
            return origin.y + block.size.height

        case .section(let children, let thumbnail):
            // The picture is pinned to the trailing edge and the prose narrowed
            // for it, which is the arrangement an embed's thumbnail already
            // takes — a section is that relationship with the card removed.
            let side = EmbedLayoutEngine.thumbnailSide
            let textWidth = thumbnail == nil
                ? width
                : max(40, width - side - EmbedLayoutEngine.gap)
            var y = origin.y
            for (index, child) in children.enumerated() {
                if index > 0 { y += 2 }
                y = place(
                    child,
                    origin: CGPoint(x: origin.x, y: y),
                    width: textWidth,
                    context: context,
                    into: &card,
                    controls: &controls
                )
            }
            if let thumbnail, let source = thumbnail.proxyURL ?? Optional(thumbnail.url) {
                card.images.append(EmbedImage(
                    rect: CGRect(
                        x: origin.x + width - side, y: origin.y, width: side, height: side
                    ),
                    url: CDN.resizedAttachment(proxyURL: source, width: side),
                    isCircle: false,
                    corner: EmbedLayoutEngine.corner,
                    decodeWidth: side,
                    isArtwork: true,
                    placeholder: thumbnail.placeholder
                ))
                // **An app's pictures open in the viewer**, as an embed's do
                // (Alex, 2026-11-17: "cant click media on apps").
                card.images[card.images.count - 1].viewerMedia = thumbnail
                y = max(y, origin.y + side)
            }
            return y

        case .gallery(let items):
            return gallery(items, origin: origin, width: width, into: &card)

        case .row(let row):
            var placed: [ComponentSlot] = []
            let bottom = TimelineLayoutEngine.layoutComponentRows(
                [row],
                contentX: origin.x,
                y: origin.y,
                width: width,
                style: context.style,
                into: &placed
            )
            for index in placed.indices { placed[index].isOnCard = true }
            controls.append(contentsOf: placed)
            return bottom

        case .container(let accent, let children):
            // Discord allows one, and a card inside a card is drawn as one.
            let inner = container(
                accent: accent,
                children: children,
                origin: origin,
                width: width,
                context: context,
                controls: &controls
            )
            card.texts.append(contentsOf: inner.texts)
            card.images.append(contentsOf: inner.images)
            card.rules.append(contentsOf: inner.rules)
            return inner.rect.maxY

        case .separator(let isDivider, let isLarge):
            let gap = isLarge ? separatorLarge : separatorSmall
            var y = origin.y + gap / 2
            if isDivider {
                card.rules.append(CGRect(
                    x: origin.x, y: y.rounded(), width: width, height: 1
                ))
                y += 1
            }
            return y + gap / 2
        }
    }

    /// A gallery: one picture full width, several in a row of equal columns.
    ///
    /// Capped at four across, which is where a thumbnail stops being big enough
    /// to recognise in a transcript column.
    private static func gallery(
        _ items: [Embed.Media],
        origin: CGPoint,
        width: CGFloat,
        into card: inout EmbedSlot
    ) -> CGFloat {
        guard !items.isEmpty else { return origin.y }
        let perRow = min(4, items.count)
        let gap = EmbedLayoutEngine.gap
        let columnWidth = (width - CGFloat(perRow - 1) * gap) / CGFloat(perRow)
        var y = origin.y
        var column = 0

        for item in items {
            let source = item.proxyURL ?? item.url
            let height = items.count == 1
                ? (item.aspectRatio.map { min(EmbedLayoutEngine.imageMaxHeight, columnWidth / $0) }
                    ?? min(EmbedLayoutEngine.imageMaxHeight, columnWidth * 0.5625))
                // A grid is squares: pictures of different heights side by side
                // is a ragged edge, and the reader is scanning rather than
                // reading them.
                : columnWidth
            let rect = CGRect(
                x: origin.x + CGFloat(column) * (columnWidth + gap),
                y: y,
                width: columnWidth,
                height: height
            )
            // **A video item is a poster that plays in place** — its
            // `content_type` said so, and asked for as a picture it was a box
            // that never filled. The proxy's still of the file, and the same
            // inline player a link's video file gets.
            let video = item.isVideo && !item.isSpoiler ? URL(string: source) : nil
            card.images.append(EmbedImage(
                rect: rect,
                url: item.isVideo
                    ? CDN.videoPoster(proxyURL: source, width: columnWidth, height: height)
                    : CDN.resizedAttachment(proxyURL: source, width: columnWidth),
                isCircle: false,
                corner: EmbedLayoutEngine.corner,
                decodeWidth: columnWidth,
                isArtwork: true,
                video: video.map(EmbedVideo.file),
                controls: video.map { EmbedPlayControls(centeredIn: rect, page: URL(string: item.url) ?? $0) },
                placeholder: item.placeholder,
                isSpoiler: item.isSpoiler
            ))
            // A picture opens in the viewer; a video plays where it is.
            if !item.isVideo { card.images[card.images.count - 1].viewerMedia = item }
            column += 1
            if column == perRow {
                column = 0
                y += height + gap
            }
        }
        return column == 0 ? y - gap : y + columnWidth
    }
}
