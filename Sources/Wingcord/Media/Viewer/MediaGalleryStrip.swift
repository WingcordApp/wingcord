import SwiftUI
import WingcordCore

/// The message's pictures in a row under the stage — Discord's gallery strip
/// (`947056`'s `Q`): a 40-point thumbnail each, the one on stage at full
/// strength and ringed, the rest dimmed; a click slides to it; the row keeps
/// the current one in view as the reader pages.
///
/// **Glass, as the bar under it is** — a control floating over the picture —
/// and the same tint, so the two read as one family.
struct MediaGalleryStrip: View {
    var request: MediaViewerRequest
    var select: (Int) -> Void

    @Environment(\.motion) private var motion

    static let side: CGFloat = 40
    private static let gap: CGFloat = 6
    private static let inset: CGFloat = 6

    var body: some View {
        let count = request.items.count
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: Self.gap) {
                    ForEach(Array(request.items.enumerated()), id: \.element.id) { index, item in
                        let isCurrent = index == request.index
                        let label = isCurrent ? "Item \(index + 1) of \(count) (current)" : "Item \(index + 1) of \(count)"
                        Button { select(index) } label: {
                            MediaStripThumbnail(item: item)
                                .frame(width: Self.side, height: Self.side)
                                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                .overlay {
                                    if isCurrent {
                                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .strokeBorder(.white, lineWidth: 2)
                                    }
                                }
                                .opacity(isCurrent ? 1 : 0.5)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .id(item.id)
                        // Discord's words, `qv/U5V` and `zviMAG`.
                        .help(label)
                        .accessibilityLabel(Text(label))
                        .accessibilityAddTraits(isCurrent ? .isSelected : [])
                    }
                }
                .padding(Self.inset)
                .animation(motion.standard, value: request.index)
            }
            .scrollIndicators(.never)
            .frame(width: min(Self.width(count: count), 440))
            // **No glass behind the thumbnails** (Alex, 2026-11-18): clear
            // glass lensed the strip's own pictures into each other, which is
            // exactly what made them hard to read over the dimmed viewer.
            .onAppear { proxy.scrollTo(request.current?.id, anchor: .center) }
            .onChange(of: request.index) {
                // Into view as the reader pages, as Discord's `scrollIntoViewNode`
                // does — and without the travel under Reduce Motion.
                let target = request.current?.id
                if motion.reduceMotion {
                    proxy.scrollTo(target, anchor: .center)
                } else {
                    withAnimation(motion.standard) { proxy.scrollTo(target, anchor: .center) }
                }
            }
        }
    }

    private static func width(count: Int) -> CGFloat {
        CGFloat(count) * side + CGFloat(max(0, count - 1)) * gap + inset * 2
    }
}

/// One thumbnail: the picture at strip size, or a clip's mark.
private struct MediaStripThumbnail: View {
    var item: MediaItem

    var body: some View {
        if item.kind == .video {
            ZStack {
                Rectangle().fill(Color(white: 0.18))
                Image(systemName: "play.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
        } else {
            RemoteImage(
                url: CDN.resizedAttachment(proxyURL: item.proxyURL, width: MediaGalleryStrip.side),
                side: MediaGalleryStrip.side,
                bucket: .thumbnail
            ) {
                Rectangle().fill(Color(white: 0.18))
            }
            .aspectRatio(contentMode: .fill)
        }
    }
}
