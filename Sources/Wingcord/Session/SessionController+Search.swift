import Foundation
import WingcordCore
import WingcordNet

// Running a message search.

extension SessionController {

    /// Runs one search and puts the answer on the store.
    ///
    /// **Last-write-wins, and the answer is checked against the question.** A
    /// reader typing produces one of these per Return and one per page click;
    /// an answer that lands after the query moved on would replace a list with
    /// results to a question nobody is looking at any more.
    func runSearch(_ query: MessageSearchQuery) {
        searchTask?.cancel()
        model.messageSearch?.isLoading = true
        model.messageSearch?.failure = nil
        model.messageSearch?.isIndexing = false

        searchTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if model.messageSearch?.draft.scope == query.scope {
                    model.messageSearch?.isLoading = false
                }
            }

            // **The 202 is a wait, not a failure**, and it is bounded. A guild
            // that has never been searched answers "index not yet available"
            // with a delay to honour; retrying for ever would be a spin against
            // a server that already said it is busy, so this gives up after a
            // few attempts and says so.
            for attempt in 0..<Self.searchIndexAttempts {
                if Task.isCancelled { return }
                do {
                    let page = try await rest.searchMessages(query)
                    guard !Task.isCancelled, model.messageSearch?.scope == query.scope else { return }
                    // The authors arrive with the page and are merged rather
                    // than replacing: a hit's author is very often somebody in
                    // no roster this client holds, and without them every row
                    // draws "Unknown" over a grey circle.
                    for (id, user) in page.authors where model.users[id] == nil {
                        model.users[id] = user
                    }
                    model.messageSearch?.page = page
                    model.messageSearch?.submitted = query
                    model.messageSearch?.isIndexing = false
                    model.identityRevision &+= 1
                    return
                } catch let indexing as DiscordREST.SearchIndexing {
                    guard model.messageSearch?.scope == query.scope else { return }
                    model.messageSearch?.isIndexing = true
                    guard attempt < Self.searchIndexAttempts - 1 else {
                        model.messageSearch?.failure =
                            "This server is still being indexed. Try again in a minute."
                        return
                    }
                    try? await Task.sleep(for: indexing.delay)
                } catch {
                    guard !Task.isCancelled, model.messageSearch?.scope == query.scope else { return }
                    Self.trace("search failed: \(Self.describe(error))")
                    model.messageSearch?.failure = Self.searchFailure(error)
                    return
                }
            }
        }
    }

    func cancelSearch() {
        searchTask?.cancel()
        searchTask = nil
    }

    /// How many times a 202 is waited out before giving up. Three attempts at
    /// the server's own delay is a few seconds — long enough for an index that
    /// is nearly ready, short enough that nobody watches a spinner instead of
    /// being told to come back.
    static let searchIndexAttempts = 3

    /// Why a search did not answer, in words somebody can act on.
    static func searchFailure(_ error: any Error) -> String {
        switch error as? DiscordREST.Failure {
        case .forbidden:
            // The route requires READ_MESSAGE_HISTORY, and a reader can hold it
            // in some of a server's channels and not others.
            "You can't search this server."
        case .api(_, _, let message?) where !message.isEmpty:
            message
        case .transport:
            "Couldn't reach Discord. Check your connection."
        default:
            "That search didn't go through. Try again in a moment."
        }
    }
}
