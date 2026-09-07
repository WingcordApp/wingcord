import Foundation
import WingcordCore

/// A search, as the window holds it.
///
/// **Two queries, deliberately.** `draft` is what the field and the filter sheet
/// edit; `submitted` is what the results on screen belong to. Collapsing them
/// into one is what makes a result list disagree with the controls above it —
/// somebody types three more characters, the header still says "842 Results",
/// and the page number now points into a search nobody ran.
struct MessageSearchState: Hashable, Sendable {
    /// What is being edited.
    var draft: MessageSearchQuery
    /// What the answer below belongs to. Nil until the first search runs.
    var submitted: MessageSearchQuery?
    var page: MessageSearchPage?
    var isLoading = false
    /// Discord is still building this guild's index — a 202, not a failure. See
    /// `DiscordREST.SearchIndexing`.
    var isIndexing = false
    var failure: String?

    init(scope: MessageSearchScope) {
        draft = MessageSearchQuery(scope: scope)
    }

    var scope: MessageSearchScope { draft.scope }

    /// Whether the draft differs from what produced the results on screen — the
    /// signal for "press Return to search again" rather than a stale list
    /// silently pretending to be current.
    var isDirty: Bool {
        guard let submitted else { return !draft.isEmpty }
        // The page is not part of the question, only of the answer.
        return submitted.onPage(1) != draft.onPage(1)
    }

    /// The page number the results belong to, which is **not** the draft's:
    /// typing in the field must not renumber a list that has not been refetched.
    var currentPage: Int { submitted?.page ?? 1 }
    var pageCount: Int { page?.pageCount ?? 0 }
    var totalResults: Int { page?.totalResults ?? 0 }

    var results: [Message] { page?.messages ?? [] }

    /// Whether there is an answer to draw at all — as opposed to a panel that
    /// has been opened and not yet used.
    var hasAnswer: Bool { submitted != nil && page != nil }
}
