import Foundation

// MARK: - Cuts and speed (docs/CLIPS-PRESENCE.md, D14 / Phase 5.1)
//
// The edited clip is a sequence of stretches of the source played back to
// back, each at its own speed. Everything timed on the clip — words, pictures,
// zooms, blurs, captions — is kept in the **source's** time, so it stays on
// the moment it marks when a stretch before it is cut or sped up; the
// sequence maps between the two clocks.

/// One kept stretch of the source, played at a speed.
public struct ClipSegment: Codable, Hashable, Sendable, Identifiable {
    public static let speeds: ClosedRange<Double> = 0.25...4
    /// The shortest stretch a split or a trim leaves.
    public static let minimumLength = 0.1

    public var id: UUID
    /// Seconds into the source.
    public var start: Double
    public var end: Double
    public var speed: Double

    public init(id: UUID = UUID(), start: Double, end: Double, speed: Double = 1) {
        self.id = id
        self.start = start
        self.end = max(start, end)
        self.speed = min(max(speed, Self.speeds.lowerBound), Self.speeds.upperBound)
    }

    /// How long it plays for.
    public var outputDuration: Double { (end - start) / speed }
}

/// The segments laid end to end on the output's clock.
public struct ClipSequence: Hashable, Sendable {
    public struct Placed: Hashable, Sendable {
        public var segment: ClipSegment
        public var outputStart: Double
        public var outputEnd: Double
    }

    public let placed: [Placed]

    public init(segments: [ClipSegment]) {
        var clock = 0.0
        placed = segments.map { segment in
            defer { clock += segment.outputDuration }
            return Placed(segment: segment, outputStart: clock, outputEnd: clock + segment.outputDuration)
        }
    }

    /// Seconds the edited clip lasts.
    public var duration: Double { placed.last?.outputEnd ?? 0 }

    /// Which segment plays at `output` seconds — the last one at the very end.
    public func index(atOutput output: Double) -> Int? {
        guard !placed.isEmpty else { return nil }
        if output >= duration { return placed.count - 1 }
        return placed.firstIndex { output < $0.outputEnd } ?? placed.count - 1
    }

    /// The moment of the source on screen at `output` seconds of the edit.
    public func sourceTime(atOutput output: Double) -> Double {
        guard let index = index(atOutput: max(0, output)) else { return 0 }
        let place = placed[index]
        let into = min(max(0, output - place.outputStart), place.outputEnd - place.outputStart)
        return place.segment.start + into * place.segment.speed
    }

    /// Where a moment of the source plays in the edit — nil when it was cut.
    public func outputTime(atSource source: Double) -> Double? {
        for place in placed where source >= place.segment.start && source <= place.segment.end {
            return place.outputStart + (source - place.segment.start) / place.segment.speed
        }
        return nil
    }

    /// Where a stretch of the source plays — once per segment it falls in.
    public func outputRanges(ofSource range: ClosedRange<Double>) -> [ClosedRange<Double>] {
        placed.compactMap { place in
            let lower = max(range.lowerBound, place.segment.start)
            let upper = min(range.upperBound, place.segment.end)
            guard upper > lower else { return nil }
            return (place.outputStart + (lower - place.segment.start) / place.segment.speed)
                ... (place.outputStart + (upper - place.segment.start) / place.segment.speed)
        }
    }
}

extension ClipEdits {
    /// The edit's segments: the v1 trim as one segment until it is cut.
    public func sequence(in duration: Double) -> ClipSequence {
        ClipSequence(segments: resolvedSegments(in: duration))
    }

    public func resolvedSegments(in duration: Double) -> [ClipSegment] {
        if !segments.isEmpty { return segments }
        let kept = range(in: duration)
        return [ClipSegment(id: Self.wholeSegmentID, start: kept.lowerBound, end: kept.upperBound)]
    }

    /// The id the v1 trim's one segment is known by until it is cut, so a
    /// selection survives the cut that makes it real.
    public static let wholeSegmentID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))

    /// Cuts the segment playing at `output` seconds in two there. Nothing
    /// happens within `ClipSegment.minimumLength` of either of its ends.
    /// - Returns: the new second half's id.
    @discardableResult
    public mutating func split(atOutput output: Double, duration: Double) -> UUID? {
        var list = resolvedSegments(in: duration)
        let sequence = ClipSequence(segments: list)
        guard let index = sequence.index(atOutput: output) else { return nil }
        let source = sequence.sourceTime(atOutput: output)
        let segment = list[index]
        guard source - segment.start >= ClipSegment.minimumLength,
              segment.end - source >= ClipSegment.minimumLength
        else { return nil }
        var first = segment
        first.end = source
        let second = ClipSegment(start: source, end: segment.end, speed: segment.speed)
        list[index] = first
        list.insert(second, at: index + 1)
        setSegments(list)
        return second.id
    }

    /// Takes a segment out, closing the gap. The last one stays.
    public mutating func removeSegment(_ id: UUID, duration: Double) {
        var list = resolvedSegments(in: duration)
        guard list.count > 1, let index = list.firstIndex(where: { $0.id == id }) else { return }
        list.remove(at: index)
        setSegments(list)
    }

    public mutating func setSpeed(_ speed: Double, of id: UUID, duration: Double) {
        var list = resolvedSegments(in: duration)
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        list[index].speed = min(max(speed, ClipSegment.speeds.lowerBound), ClipSegment.speeds.upperBound)
        setSegments(list)
    }

    /// Moves a segment's ends — never past its neighbours, never shorter
    /// than `ClipSegment.minimumLength`, never outside the file.
    public mutating func trimSegment(_ id: UUID, start: Double? = nil, end: Double? = nil, duration: Double) {
        var list = resolvedSegments(in: duration)
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        let floor = index > 0 ? list[index - 1].end : 0
        let ceiling = index + 1 < list.count ? list[index + 1].start : duration
        if let start {
            list[index].start = min(max(floor, start), list[index].end - ClipSegment.minimumLength)
        }
        if let end {
            list[index].end = max(min(ceiling, end), list[index].start + ClipSegment.minimumLength)
        }
        setSegments(list)
    }

    /// Writes segments and keeps the v1 trim — what a v1 reader and the
    /// library's length see — at their outer ends. The v1 trim's own segment,
    /// untouched, stays the trim; any other keeps its id, so a selection by
    /// id survives the next change.
    public mutating func setSegments(_ list: [ClipSegment]) {
        let ordered = list.sorted { $0.start < $1.start }
        let isWhole = ordered.count == 1 && ordered[0].speed == 1 && ordered[0].id == Self.wholeSegmentID
        segments = isWhole ? [] : ordered
        if let first = ordered.first { start = first.start }
        if let last = ordered.last { end = last.end }
    }
}

extension ClipManifest {
    /// The timeline as the edited clip plays it — Discord's `lz` once per
    /// kept stretch (who was speaking carried in at each cut), each moved to
    /// where the stretch plays and squeezed by its speed.
    public func timeline(through sequence: ClipSequence) -> [ClipTimelineEvent] {
        var events: [ClipTimelineEvent] = []
        for place in sequence.placed {
            let stretch = timeline(trimmedTo: place.segment.start...place.segment.end)
            for event in stretch {
                let moved = place.outputStart + Double(event.timestampMS) / 1_000 / place.segment.speed
                events.append(ClipTimelineEvent(timestampMS: Int((moved * 1_000).rounded()), event: event.event))
            }
        }
        return Array(events.prefix(ClipTimeline.eventLimit))
    }
}
