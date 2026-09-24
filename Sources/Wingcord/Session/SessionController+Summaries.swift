import Foundation
import WingcordCore
import WingcordNet

// MARK: - Summaries
//
// The fetches behind `AppModel+Summaries`. Which to make, and when, is the
// store's; this only makes them and lands the answers.

extension SessionController {

    func loadSummaries(in channelID: ChannelID, _ request: SummaryRequest) {
        Task { [weak self] in
            guard let self else { return }
            switch request {
            case .list:
                do {
                    let summaries = try await rest.channelSummaries(in: channelID)
                    Self.trace("summaries \(channelID): \(summaries.count)")
                    model.applySummaries(summaries, in: channelID)
                } catch {
                    Self.trace("summaries \(channelID) FAILED: \(Self.describe(error))")
                    model.failSummaries(in: channelID, refused: !Self.isWorthRetrying(error))
                }
            case .one(let summaryID):
                do {
                    guard let summary = try await rest.channelSummary(summaryID, in: channelID)
                    else { return }
                    model.mergeSummaries([summary], in: channelID)
                } catch {
                    // The list's copy stands; the mark and the bar still work.
                    Self.trace("summary \(summaryID) FAILED: \(Self.describe(error))")
                }
            }
        }
    }
}
