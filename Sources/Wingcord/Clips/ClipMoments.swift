import SwiftUI
import WingcordCore

/// One mark on a clip's scrubber: a moment of the game, an emotion, or a
/// timeline comment.
///
/// **One vocabulary for the editor's timeline and the player's scrubber**, so
/// a kill is the same glyph in both.
struct ClipMark: Identifiable, Equatable {
    enum Kind: Equatable {
        case game(ClipGameEventType, name: String)
        case emotion(ClipEmotion)
        case comment(TimelineComment)
    }

    var id: String
    var seconds: Double
    var kind: Kind

    /// What the mark's tooltip leads with — the event's own name, Discord's
    /// word for the emotion, or who commented.
    var title: String {
        switch kind {
        case .game(let type, let name):
            if !name.isEmpty { return name }
            return switch type {
            case .kill: "Kill"
            case .multikill: "Multikill"
            case .death: "Death"
            case .unknown: "In-game event"
            }
        // Discord's `bTC23D` and `3gqpuo`.
        case .emotion(.laughter): return "LOL"
        case .emotion(.shouting): return "Shouting"
        case .comment(let comment): return comment.authorName
        }
    }

    /// The line under it — Discord's `347DBb` / `ry+jxm`, or the comment.
    var detail: String {
        switch kind {
        case .game: "In-game event"
        case .emotion: "Emotional moment"
        case .comment(let comment): comment.content
        }
    }

    var symbolName: String {
        switch kind {
        case .game(.kill, _): "scope"
        case .game(.multikill, _): "flame.fill"
        case .game(.death, _): "xmark.circle.fill"
        case .game(.unknown, _): "star.circle.fill"
        case .emotion(.laughter): "face.smiling.inverse"
        case .emotion(.shouting): "megaphone.fill"
        case .comment: "text.bubble.fill"
        }
    }

    var tint: Color {
        switch kind {
        case .game(.death, _): Palette.destructive
        case .game: .yellow
        case .emotion: .orange
        case .comment: InkColor.solid
        }
    }

    /// Which of two marks too close to tell apart is kept — Discord keeps the
    /// one its table ranks higher.
    private var priority: Int {
        switch kind {
        case .game(.multikill, _): 4
        case .game(.kill, _): 3
        case .emotion: 2
        case .game(.death, _), .game(.unknown, _): 1
        case .comment: 0
        }
    }

    /// A clip's moments for a scrubber `duration` seconds long, as Discord's
    /// player picks them (module 349897's `useClipTimelineIndicators`): game
    /// events and emotions; of two closer than `spacing` of the length, the
    /// higher ranked; in time order.
    static func moments(in timeline: [ClipTimelineEvent], duration: Double, spacing: Double = 0.02) -> [ClipMark] {
        guard duration > 0 else { return [] }
        var candidates: [ClipMark] = []
        for (index, entry) in timeline.enumerated() {
            let seconds = Double(entry.timestampMS) / 1_000
            guard seconds >= 0, seconds <= duration else { continue }
            switch entry.event {
            case .game(let type, let name):
                candidates.append(ClipMark(id: "event-\(index)", seconds: seconds, kind: .game(type, name: name)))
            case .emotion(let emotion):
                candidates.append(ClipMark(id: "event-\(index)", seconds: seconds, kind: .emotion(emotion)))
            case .speaking:
                continue
            }
        }
        let ranked = candidates.sorted { ($0.priority, -$0.seconds) > ($1.priority, -$1.seconds) }
        var kept: [ClipMark] = []
        for mark in ranked where !kept.contains(where: { abs($0.seconds - mark.seconds) / duration < spacing }) {
            kept.append(mark)
        }
        return kept.sorted { $0.seconds < $1.seconds }
    }

    /// A clip's timeline comments as marks.
    static func comments(_ comments: [TimelineComment], duration: Double) -> [ClipMark] {
        guard duration > 0 else { return [] }
        return comments.map { comment in
            ClipMark(
                id: "comment-\(comment.id.rawValue)",
                seconds: min(duration, Double(comment.timestampMS) / 1_000),
                kind: .comment(comment)
            )
        }
    }
}
