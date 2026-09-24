import Foundation
import WingcordCore
import WingcordNet

// MARK: - Summaries
//
// Discord's older summaries feature: stretches of a channel it has titled and
// summed up in a sentence, drawn as a bar under the toolbar — the stretch the
// reader is in, and the way to the ones either side. The store is Discord's own
// (module `822074`), the fetches its `863922`, the gate its `432371`.

/// One channel's summaries, and what has been asked.
struct ChannelSummaries: Equatable, Sendable {
    /// Newest first by where each begins — the order every index into the list
    /// is taken in. See `ChannelSummary.newestFirst`.
    var summaries: [ChannelSummary] = []
    /// The list was asked for and answered this session.
    ///
    /// **Discord asks once per session and keeps the list current from the
    /// gateway** — `shouldFetch` is "not fetching and never answered". The one
    /// place this differs: a live update that lands before the channel is ever
    /// opened does not count as the answer. Discord's store stamps it as one,
    /// and a channel whose first news was a single new summary then shows that
    /// one summary for the rest of the session.
    var hasFetched = false
    var isLoading = false
    /// The server refused: draw nothing, and do not ask again this session.
    var isUnavailable = false
}

/// The summary the reader went to.
///
/// **Kept until they leave the channel or pick another** — Discord's
/// `SET_SELECTED_SUMMARY`, cleared on `CHANNEL_SELECT` and on nothing else, so
/// its mark does not vanish when scrolled past the way a topic's does.
struct SelectedSummary: Equatable, Sendable {
    var channelID: ChannelID
    var summaryID: ChannelSummaryID
    /// Distinguishes going to the same summary twice. See `TimelineView`'s
    /// use of it: each going is one landing, and the bar names it until the
    /// reader scrolls.
    var token: UInt64
}

/// What the store asks the session for.
enum SummaryRequest: Equatable, Sendable {
    /// The channel's whole list.
    case list
    /// One summary, as it stands now.
    case one(ChannelSummaryID)
}

/// Where the reader is among a channel's summaries — what the bar names, and
/// where its arrows go.
///
/// **Discord's rule for the name** (module `822074`, `UPDATE_VISIBLE_MESSAGES`):
/// the first summary in the list — so the newest — whose stretch overlaps the
/// messages on screen, or the one the reader just went to. **Its arrows are
/// made to mean where they point**: in a summary they step to the next older
/// and newer one, as Discord's do, and between summaries they go to the nearest
/// one above and below — where Discord's up arrow jumps to the newest summary
/// in the channel, which is usually below the reader.
nonisolated struct SummaryPlace: Equatable, Sendable {
    /// The summary named, as an index into the channel's list.
    var current: Int?
    /// Where the up arrow goes: the next stretch back in the channel.
    var older: Int?
    /// Where the down arrow goes.
    var newer: Int?
    /// The reader is at the channel's present, where nothing overlapping the
    /// screen still names the newest summary — Discord's own fallback.
    var isAtPresent: Bool

    /// - Parameters:
    ///   - top, bottom: the first and last messages that can be read, or nil
    ///     at the present.
    ///   - highlighted: the summary the reader just went to, named until they
    ///     scroll.
    ///   - summaries: newest first.
    init(
        top: MessageID?,
        bottom: MessageID?,
        highlighted: ChannelSummaryID?,
        summaries: [ChannelSummary]
    ) {
        isAtPresent = top == nil
        if let highlighted, let index = summaries.firstIndex(where: { $0.id == highlighted }) {
            current = index
        } else if let top, let bottom {
            // Discord's overlap, verbatim: `!(top > end) && !(bottom < start)`.
            current = summaries.firstIndex {
                top.rawValue <= $0.endMessageID.rawValue
                    && bottom.rawValue >= $0.startMessageID.rawValue
            }
        } else {
            current = nil
        }

        if let current {
            older = current + 1 < summaries.count ? current + 1 : nil
            newer = current > 0 ? current - 1 : nil
        } else if let top, let bottom {
            // Wholly above the screen, nearest first; wholly below, nearest
            // last — the list runs newest first.
            older = summaries.firstIndex { $0.endMessageID.rawValue < top.rawValue }
            newer = summaries.lastIndex { $0.startMessageID.rawValue > bottom.rawValue }
        } else {
            // At the present every summary is behind the reader.
            older = summaries.isEmpty ? nil : 0
            newer = nil
        }
    }

    /// What the bar's pill says.
    func title(in summaries: [ChannelSummary]) -> String {
        let named = current.map { summaries[$0].topic }
            ?? (isAtPresent ? summaries.first?.topic : nil)
        guard let named, !named.isEmpty else { return Self.allSummaries }
        return named
    }

    /// Discord's words for the pill when no stretch is named — it opens the
    /// list, so it says so.
    static let allSummaries = "View All Summaries"
}

extension AppModel {

    /// Discord's two server flags, both required: the feature, and the owner
    /// having it switched on (module `432371`).
    static let summaryFeatures = ["SUMMARIES_ENABLED_GA", "SUMMARIES_ENABLED_BY_USER"]
    /// How long a summary asked for on its own counts as fresh — Discord's
    /// five seconds (`hf` in module `521732`).
    static let summaryRefreshInterval: TimeInterval = 5

    /// Whether this channel can have summaries — Discord's gate, line for line.
    ///
    /// **A plain text channel only** (`SUMMARIZEABLE` is `{0}`), not an
    /// age-restricted one, not the rules channel, not one the server switched
    /// off, in a server not marked age-restricted that has both flags. Nothing
    /// about the reader: Discord asks nothing of them here either.
    func summariesApply(to channelID: ChannelID) -> Bool {
        guard let channel = channelIndex[channelID],
              channel.kind == .text,
              !channel.isNSFW,
              !channel.flags.contains(.summariesDisabled),
              let guildID = channel.guildID,
              let guild = guilds[guildID],
              guild.rulesChannelID != channelID,
              !guild.isAgeRestricted
        else { return false }
        return Self.summaryFeatures.allSatisfy(guild.features.contains)
    }

    /// The channel's summaries, newest first — empty until they arrive.
    func summaries(in channelID: ChannelID) -> [ChannelSummary] {
        channelSummaries[channelID]?.summaries ?? []
    }

    /// Asks for the channel's summaries, once per session.
    func loadSummariesIfNeeded(in channelID: ChannelID) {
        guard summariesApply(to: channelID), let summaryLoader else { return }
        let state = channelSummaries[channelID]
        guard state?.hasFetched != true, state?.isLoading != true, state?.isUnavailable != true
        else { return }
        channelSummaries[channelID, default: ChannelSummaries()].isLoading = true
        summaryLoader(channelID, .list)
    }

    /// The list landed.
    ///
    /// **Laid over what is held, not in place of it**: anything the gateway
    /// delivered while the request was out is newer than the snapshot and
    /// stays; everything the snapshot names replaces its held copy.
    func applySummaries(_ summaries: [ChannelSummary], in channelID: ChannelID) {
        var state = channelSummaries[channelID] ?? ChannelSummaries()
        state.summaries = ChannelSummary.merging(summaries, into: state.summaries)
        state.hasFetched = true
        state.isLoading = false
        channelSummaries[channelID] = state
    }

    /// The list did not land. A refusal is final for the session; a dropped
    /// connection lets the next visit ask again.
    func failSummaries(in channelID: ChannelID, refused: Bool) {
        guard var state = channelSummaries[channelID] else { return }
        state.isLoading = false
        if refused { state.isUnavailable = true }
        channelSummaries[channelID] = state
    }

    /// New or changed summaries from the gateway, or one asked for on its own.
    ///
    /// **Through the gate like a fetch.** Discord's store takes a live update
    /// for any channel and its bar checks the gate when it draws; the bar here
    /// draws whatever list a channel holds, so the gate is checked on the way
    /// in instead — or an update for a rules channel would raise a bar Discord
    /// never shows.
    func mergeSummaries(_ summaries: [ChannelSummary], in channelID: ChannelID) {
        guard summariesApply(to: channelID) else { return }
        let held = channelSummaries[channelID]?.summaries ?? []
        let merged = ChannelSummary.merging(summaries, into: held)
        guard merged != held else { return }
        channelSummaries[channelID, default: ChannelSummaries()].summaries = merged
    }

    /// A new session may have missed updates while it was away: every list is
    /// asked for again on its next visit. The lists themselves stay, so no bar
    /// empties while its channel is on screen.
    func markSummariesStale() {
        guard channelSummaries.values.contains(where: \.hasFetched) else { return }
        for channelID in channelSummaries.keys {
            channelSummaries[channelID]?.hasFetched = false
        }
    }

    /// Goes to a summary: the transcript jumps to where it begins, and its mark
    /// goes above that message.
    ///
    /// Discord's `setSelectedSummary` plus its jump: the summary is asked for
    /// again on its own, so a stretch that has grown since the list arrived is
    /// marked with its new title and count, and the landing flashes.
    func openSummary(_ summary: ChannelSummary, in channelID: ChannelID) {
        selectedSummaryToken &+= 1
        selectedSummary = SelectedSummary(
            channelID: channelID,
            summaryID: summary.id,
            token: selectedSummaryToken
        )
        refreshSummary(summary.id, in: channelID)
        sessionController.jumpToMessage(summary.startMessageID, in: channelID)
    }

    /// Asks for one summary as it stands now, unless it was asked for moments
    /// ago.
    private func refreshSummary(_ summaryID: ChannelSummaryID, in channelID: ChannelID) {
        let now = Date.now
        if let last = summaryRefreshes[summaryID],
           now.timeIntervalSince(last) < Self.summaryRefreshInterval
        {
            return
        }
        summaryRefreshes[summaryID] = now
        summaryLoader?(channelID, .one(summaryID))
    }

    /// The selected summary's mark in this channel's transcript, if it has one.
    ///
    /// Resolved against the channel's list rather than carried whole, so a
    /// refreshed summary re-titles its mark.
    func summaryMark(in channelID: ChannelID) -> TimelineMark? {
        guard let selectedSummary, selectedSummary.channelID == channelID,
              let summary = channelSummaries[channelID]?.summaries
                  .first(where: { $0.id == selectedSummary.summaryID })
        else { return nil }
        return TimelineMark(
            kind: .summary,
            id: summary.id.rawValue,
            title: summary.topic,
            startMessageID: summary.startMessageID,
            messageCount: summary.messageCount
        )
    }
}
