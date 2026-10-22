import Foundation
import WingcordCore

// MARK: - What the library shows
//
// docs/CLIPS-PRESENCE.md, Phase 4.2 — Discord's Clips Home filters, in its own
// words: Type (here: clips, recordings, screenshots), Date (Today, Yesterday,
// Last 3 Days, This Year, Last Year), the game, favourites, and "Search clips".

/// One thing in the clips folder, with what the list needs to know about it.
struct ClipLibraryItem: Identifiable, Hashable, Sendable {
    var clip: Clip

    var id: URL { clip.url }
    var url: URL { clip.url }

    nonisolated enum Kind: Hashable, Sendable {
        case clip, recording, screenshot
    }

    var kind: Kind {
        clip.isRecording ? .recording : clip.isScreenshot ? .screenshot : .clip
    }

    /// What the card is called: the clip's own title once it has one, else
    /// the file's name.
    var title: String {
        if let title = clip.manifest?.title, !title.isEmpty { return title }
        return clip.name
    }

    var game: String? {
        clip.manifest?.game?.name
    }

    /// Seconds, when it moves.
    var duration: Double? {
        clip.manifest?.duration ?? clip.take?.duration
    }

    var participants: [ClipParticipant] {
        clip.manifest?.participants ?? []
    }

    /// Why Auto Clips kept it — Discord's chip: "In-game event", "LOL",
    /// "Shouting". Nil for a clip somebody asked for.
    var autoReason: AutoClipReason? {
        clip.manifest?.isAutoClip == true ? clip.manifest?.autoReason : nil
    }

    /// The words a search looks through.
    var searchText: String {
        ([title, clip.name, game ?? ""] + participants.map(\.name)).joined(separator: " ")
    }
}

struct ClipLibraryFilter: Equatable, Sendable {
    enum Kind: String, CaseIterable, Identifiable, Sendable {
        case all, clips, recordings, screenshots

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: "All"
            case .clips: "Clips"
            case .recordings: "Recordings"
            case .screenshots: "Screenshots"
            }
        }
    }

    /// Discord's date presets (`yOAWWM` Today, `PtV/Ti` Yesterday, `xfmv7I`
    /// Last 3 Days, `+eE7zX` This Year, `Nwj9v0` Last Year).
    enum DateRange: String, CaseIterable, Identifiable, Sendable {
        case any, today, yesterday, lastThreeDays, thisYear, lastYear

        var id: String { rawValue }

        var title: String {
            switch self {
            case .any: "Any Time"
            case .today: "Today"
            case .yesterday: "Yesterday"
            case .lastThreeDays: "Last 3 Days"
            case .thisYear: "This Year"
            case .lastYear: "Last Year"
            }
        }

        func contains(_ date: Date, now: Date, calendar: Calendar) -> Bool {
            switch self {
            case .any:
                return true
            case .today:
                return calendar.isDate(date, inSameDayAs: now)
            case .yesterday:
                guard let yesterday = calendar.date(byAdding: .day, value: -1, to: now) else { return false }
                return calendar.isDate(date, inSameDayAs: yesterday)
            case .lastThreeDays:
                let start = calendar.startOfDay(for: now)
                guard let from = calendar.date(byAdding: .day, value: -2, to: start) else { return false }
                return date >= from && date <= now
            case .thisYear:
                return calendar.component(.year, from: date) == calendar.component(.year, from: now)
            case .lastYear:
                return calendar.component(.year, from: date) == calendar.component(.year, from: now) - 1
            }
        }
    }

    var kind: Kind = .all
    var date: DateRange = .any
    var game: String?
    var favouritesOnly = false
    /// Discord's "Auto clips" link: only clips Auto Clips kept.
    var autoOnly = false
    var query = ""

    /// Whether anything narrows the list — the library then drops its Recent
    /// row and shows only what matches.
    var isActive: Bool {
        kind != .all || date != .any || game != nil || favouritesOnly || autoOnly
            || !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func matches(_ item: ClipLibraryItem, isFavourite: Bool, now: Date = .now, calendar: Calendar = .current) -> Bool {
        switch kind {
        case .all: break
        case .clips: guard item.kind == .clip else { return false }
        case .recordings: guard item.kind == .recording else { return false }
        case .screenshots: guard item.kind == .screenshot else { return false }
        }
        guard date.contains(item.clip.created, now: now, calendar: calendar) else { return false }
        if let game, item.game != game { return false }
        if favouritesOnly, !isFavourite { return false }
        if autoOnly, item.clip.manifest?.isAutoClip != true { return false }
        let words = query.split(whereSeparator: \.isWhitespace)
        return words.allSatisfy { item.searchText.localizedCaseInsensitiveContains($0) }
    }
}
