import SwiftUI
import WingcordCore

// MARK: - The editor's timeline
//
// docs/CLIPS-PRESENCE.md, D14 / Phase 5.3. The edit on its own clock, a lane
// each: the game's moments; the kept stretches with their pictures, each
// selectable, trimmed by its ends, marked with its speed; the sound; then a
// lane for each kind of thing laid on the clip — zooms, blurs, captions,
// words, pictures — as bars dragged to move or by an end to resize. What is
// timed on the source's clock is drawn where it plays, once per stretch it
// falls in (HIG: "clicking a precise seek destination on a video scrubber" is
// input worth precision).

struct ClipTimelineView: View {
    var editor: ClipEditorModel

    static let stripHeight: CGFloat = 52
    static let laneHeight: CGFloat = 20
    static let inset: CGFloat = 12

    var body: some View {
        GeometryReader { geometry in
            let map = TimelineMap(
                width: geometry.size.width, inset: Self.inset, duration: max(editor.outputDuration, 0.01),
                sequence: editor.sequence
            )
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 5) {
                    moments(map)
                        .frame(height: 14)
                    ZStack(alignment: .topLeading) {
                        Color.clear
                            .contentShape(.rect)
                            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                                editor.seek(to: map.outputTime(at: value.location.x))
                            })
                        ForEach(Array(editor.sequence.placed.enumerated()), id: \.element.segment.id) { index, place in
                            SegmentBlock(editor: editor, place: place, map: map, isLast: index == editor.sequence.placed.count - 1)
                        }
                    }
                    .frame(height: Self.stripHeight)
                    .coordinateSpace(.named("timeline"))
                    if !editor.waveform.isEmpty {
                        Waveform(editor: editor, map: map)
                            .frame(height: 22)
                            .allowsHitTesting(false)
                    }
                    lanes(map)
                }
                .overlay(alignment: .topLeading) {
                    Capsule()
                        .fill(InkColor.solid)
                        .frame(width: 2)
                        .shadow(color: .black.opacity(0.4), radius: 1.5)
                        .offset(x: map.x(editor.currentTime) - 1)
                        .allowsHitTesting(false)
                }
            }
            .scrollIndicators(.never)
        }
    }

    // MARK: Moments

    /// A ruler of seconds, dragged to move the playhead, with the game's
    /// moments marked where they play.
    private func moments(_ map: TimelineMap) -> some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, size in
                let seconds = Int(map.duration.rounded(.down))
                let every = seconds > 60 ? 10 : seconds > 20 ? 5 : 1
                for second in stride(from: 0, through: seconds, by: every) {
                    let x = map.x(Double(second))
                    context.fill(Path(CGRect(x: x, y: size.height - 5, width: 1, height: 5)), with: .color(.white.opacity(0.35)))
                }
            }
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                editor.seek(to: map.outputTime(at: value.location.x))
            })
            ForEach(ClipMark.moments(in: editor.timeline, duration: max(editor.sourceDuration, 0.01), spacing: 0)) { mark in
                if let output = editor.sequence.outputTime(atSource: mark.seconds) {
                    Image(symbol: mark.symbolName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(mark.tint)
                        .position(x: map.x(output), y: 7)
                        .help("\(mark.title) — \(mark.detail)")
                        .onTapGesture { editor.seek(to: output) }
                }
            }
        }
    }

    // MARK: Lanes

    @ViewBuilder
    private func lanes(_ map: TimelineMap) -> some View {
        if !editor.edits.zooms.isEmpty {
            lane {
                ForEach(editor.edits.zooms) { zoom in
                    TimedBar(
                        editor: editor, map: map, selection: .zoom(zoom.id),
                        title: zoom.isSuggested ? "Zoom ✦ \(Self.scale(zoom.scale))" : "Zoom \(Self.scale(zoom.scale))",
                        symbol: "plus.magnifyingglass", tint: .teal, start: zoom.start, end: zoom.end
                    ) { start, end in
                        guard let index = editor.edits.zooms.firstIndex(where: { $0.id == zoom.id }) else { return }
                        editor.edits.zooms[index].start = start
                        editor.edits.zooms[index].end = end
                    }
                }
            }
        }
        if !editor.edits.blurs.isEmpty {
            lane {
                ForEach(editor.edits.blurs) { blur in
                    TimedBar(
                        editor: editor, map: map, selection: .blur(blur.id), title: blur.style.title,
                        symbol: blur.style == .blur ? "drop.halffull" : "squareshape.split.3x3", tint: .indigo,
                        start: blur.start, end: blur.end
                    ) { start, end in
                        guard let index = editor.edits.blurs.firstIndex(where: { $0.id == blur.id }) else { return }
                        editor.edits.blurs[index].start = start
                        editor.edits.blurs[index].end = end
                    }
                }
            }
        }
        if !editor.edits.captions.isEmpty, editor.edits.showsCaptions {
            lane {
                ForEach(editor.edits.captions) { caption in
                    TimedBar(
                        editor: editor, map: map, selection: .caption(caption.id), title: caption.text,
                        symbol: "captions.bubble", tint: .orange, start: caption.start, end: caption.end
                    ) { start, end in
                        guard let index = editor.edits.captions.firstIndex(where: { $0.id == caption.id }) else { return }
                        editor.edits.captions[index].start = start
                        editor.edits.captions[index].end = end
                    }
                }
            }
        }
        if !editor.edits.texts.isEmpty {
            lane {
                ForEach(editor.edits.texts) { text in
                    TimedBar(
                        editor: editor, map: map, selection: .overlay(text.id), title: text.text,
                        symbol: "textformat", tint: Palette.accent, start: text.start, end: text.end
                    ) { start, end in
                        guard let index = editor.edits.texts.firstIndex(where: { $0.id == text.id }) else { return }
                        editor.edits.texts[index].start = start
                        editor.edits.texts[index].end = end
                    }
                }
            }
        }
        if !editor.edits.images.isEmpty {
            lane {
                ForEach(editor.edits.images) { image in
                    TimedBar(
                        editor: editor, map: map, selection: .overlay(image.id), title: "Image",
                        symbol: "photo", tint: .purple, start: image.start, end: image.end
                    ) { start, end in
                        guard let index = editor.edits.images.firstIndex(where: { $0.id == image.id }) else { return }
                        editor.edits.images[index].start = start
                        editor.edits.images[index].end = end
                    }
                }
            }
        }
    }

    private func lane(@ViewBuilder content: () -> some View) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            content()
        }
        .frame(height: Self.laneHeight)
    }

    nonisolated static func scale(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1))) + "×"
    }
}

/// The edit's clock across the timeline's width — and back.
nonisolated struct TimelineMap {
    var width: CGFloat
    var inset: CGFloat
    var duration: Double
    var sequence: ClipSequence

    var usable: CGFloat { max(width - inset * 2, 1) }

    func x(_ output: Double) -> CGFloat { inset + CGFloat(output / duration) * usable }

    func outputTime(at x: CGFloat) -> Double { min(max(0, Double((x - inset) / usable) * duration), duration) }

    /// Seconds of the edit a drag of `points` covers.
    func seconds(forPoints points: CGFloat) -> Double { Double(points / usable) * duration }
}

// MARK: - A kept stretch

/// One segment: its pictures, its speed, its ends to trim.
///
/// **Everything it shows is worked out in `body` itself and handed down as
/// values.** Calling back into the editor from inside the `ZStack`'s builder
/// made the compiler check the main actor at run time there, and that check
/// crashed in the concurrency runtime during layout (2026-10-21, the editor's
/// first opening) — so the builder only ever composes plain views.
private struct SegmentBlock: View {
    var editor: ClipEditorModel
    var place: ClipSequence.Placed
    var map: TimelineMap
    var isLast: Bool

    var body: some View {
        let left = map.x(place.outputStart)
        let right = map.x(place.outputEnd)
        let isSelected = editor.selection == .segment(place.segment.id)
        let width = max(4, right - left - 2)
        let pictures = Self.pictures(for: place.segment, from: editor.filmstrip, width: width)
        let speed = place.segment.speed == 1 ? nil : ClipTimelineView.scale(place.segment.speed)
        let id = place.segment.id
        return ZStack(alignment: .topLeading) {
            SegmentPictures(images: pictures)
                .frame(width: width, height: ClipTimelineView.stripHeight)
                .clipShape(.rect(cornerRadius: 6))
            if let speed {
                SpeedBadge(text: speed)
            }
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isSelected ? Color.yellow : .white.opacity(0.25), lineWidth: isSelected ? 3 : 1)
                .frame(width: width, height: ClipTimelineView.stripHeight)
                .allowsHitTesting(false)
            if isSelected {
                SegmentEdge(editor: editor, place: place, map: map, side: .leading)
                SegmentEdge(editor: editor, place: place, map: map, side: .trailing)
                    .offset(x: width - SegmentEdge.width)
            }
        }
        .frame(width: width, height: ClipTimelineView.stripHeight, alignment: .topLeading)
        .contentShape(.rect)
        // Selects the segment and puts the playhead where it was clicked.
        .onTapGesture(coordinateSpace: .local) { location in
            editor.selection = .segment(id)
            editor.seek(to: place.outputStart + map.seconds(forPoints: location.x))
        }
        .offset(x: left + 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Segment, \(ClipEditorView.time(place.outputEnd - place.outputStart))\(speed.map { " at \($0)" } ?? "")")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The source's pictures for this stretch, as many as fit its width.
    nonisolated static func pictures(for segment: ClipSegment, from filmstrip: [(time: Double, image: CGImage)], width: CGFloat) -> [CGImage] {
        let frames = filmstrip.filter { $0.time >= segment.start - 0.3 && $0.time <= segment.end + 0.3 }
        guard !frames.isEmpty else { return [] }
        let count = max(1, min(frames.count, Int(width / 40)))
        let step = max(1, frames.count / count)
        return stride(from: 0, to: frames.count, by: step).map { frames[$0].image }
    }
}

private struct SegmentPictures: View {
    var images: [CGImage]

    var body: some View {
        HStack(spacing: 0) {
            if images.isEmpty {
                Rectangle().fill(Ink.quaternary)
            } else {
                ForEach(Array(images.enumerated()), id: \.offset) { _, image in
                    Image(decorative: image, scale: 2)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                }
            }
        }
    }
}

private struct SpeedBadge: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.system(.caption2, weight: .bold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.black.opacity(0.65), in: .capsule)
            .padding(4)
    }
}

/// An end of a segment, dragged to trim it.
private struct SegmentEdge: View {
    var editor: ClipEditorModel
    var place: ClipSequence.Placed
    var map: TimelineMap
    var side: HorizontalEdge

    static let width: CGFloat = 11
    @State private var dragOrigin: Double?

    var body: some View {
        UnevenRoundedRectangle(
            topLeadingRadius: side == .leading ? 6 : 0, bottomLeadingRadius: side == .leading ? 6 : 0,
            bottomTrailingRadius: side == .trailing ? 6 : 0, topTrailingRadius: side == .trailing ? 6 : 0
        )
        .fill(.yellow)
        .overlay { Capsule().fill(.black.opacity(0.5)).frame(width: 2, height: 18) }
        .frame(width: Self.width, height: ClipTimelineView.stripHeight)
        .gesture(DragGesture(minimumDistance: 1).onChanged { value in
            let origin = dragOrigin ?? (side == .leading ? place.segment.start : place.segment.end)
            if dragOrigin == nil {
                dragOrigin = origin
                editor.beginChange()
            }
            let shift = map.seconds(forPoints: value.translation.width) * place.segment.speed
            if side == .leading {
                editor.edits.trimSegment(place.segment.id, start: origin + shift, duration: editor.sourceDuration)
            } else {
                editor.edits.trimSegment(place.segment.id, end: origin + shift, duration: editor.sourceDuration)
            }
        }.onEnded { _ in
            dragOrigin = nil
            editor.endChange("Trim")
        })
        .pointerStyle(.frameResize(position: side == .leading ? .leading : .trailing))
        .accessibilityLabel(side == .leading ? "Start of the segment" : "End of the segment")
    }
}

// MARK: - The sound

private struct Waveform: View {
    var editor: ClipEditorModel
    var map: TimelineMap

    var body: some View {
        Canvas { context, size in
            let peaks = editor.waveform
            guard !peaks.isEmpty, editor.sourceDuration > 0 else { return }
            let colour = GraphicsContext.Shading.color(.green.opacity(0.75))
            for place in editor.sequence.placed {
                let left = map.x(place.outputStart)
                let right = map.x(place.outputEnd)
                var x = left
                while x < right {
                    let output = map.outputTime(at: x)
                    let source = editor.sequence.sourceTime(atOutput: output)
                    let bucket = min(peaks.count - 1, max(0, Int(source / editor.sourceDuration * Double(peaks.count))))
                    let height = max(1, CGFloat(peaks[bucket]) * size.height)
                    context.fill(Path(CGRect(x: x, y: (size.height - height) / 2, width: 1.5, height: height)), with: colour)
                    x += 2.5
                }
            }
        }
    }
}

// MARK: - A bar of something laid on the clip

/// One zoom, blur, caption, word or picture: the middle moves it, an end
/// resizes it, on the source's clock. Drawn once per stretch it plays in.
private struct TimedBar: View {
    var editor: ClipEditorModel
    var map: TimelineMap
    var selection: ClipEditorModel.Selection
    var title: String
    var symbol: String
    var tint: Color
    var start: Double
    var end: Double
    var update: (Double, Double) -> Void

    private enum Part { case move, leading, trailing }
    @State private var origin: (start: Double, end: Double, part: Part)?

    var body: some View {
        let ranges = editor.sequence.outputRanges(ofSource: start...max(start, end))
        let isSelected = editor.selection == selection
        ForEach(Array(ranges.enumerated()), id: \.offset) { _, range in
            let left = map.x(range.lowerBound)
            let right = map.x(range.upperBound)
            Label(title, systemImage: symbol)
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .frame(width: max(18, right - left), height: ClipTimelineView.laneHeight, alignment: .leading)
                .background(tint.opacity(isSelected ? 1 : 0.7), in: .rect(cornerRadius: 5))
                .overlay {
                    if isSelected { RoundedRectangle(cornerRadius: 5).strokeBorder(.white, lineWidth: 1.5) }
                }
                .offset(x: left)
                .onTapGesture { editor.selection = selection }
                .gesture(drag(width: right - left))
                .help(title)
        }
    }

    private func drag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2).onChanged { value in
            if origin == nil {
                origin = (start, end, value.startLocation.x < 7 ? .leading : value.startLocation.x > width - 7 ? .trailing : .move)
                editor.beginChange()
            }
            guard let origin else { return }
            // Seconds of the source under the drag, at the speed it plays.
            let speed = editor.sequence.placed.first { origin.start >= $0.segment.start && origin.start <= $0.segment.end }?.segment.speed ?? 1
            let shift = map.seconds(forPoints: value.translation.width) * speed
            let limit = editor.sourceDuration
            switch origin.part {
            case .move:
                let length = origin.end - origin.start
                let from = min(max(0, origin.start + shift), limit - length)
                update(from, from + length)
            case .leading:
                update(min(max(0, origin.start + shift), origin.end - 0.2), origin.end)
            case .trailing:
                update(origin.start, max(min(limit, origin.end + shift), origin.start + 0.2))
            }
            editor.selection = selection
        }.onEnded { _ in
            origin = nil
            editor.endChange("Move")
        }
    }
}
