import Foundation
import WingcordCore

/// The Add a Server sheet, as a value on the store.
///
/// **The typed text lives here rather than in the sheet's own `@State`**, for
/// the reason every other raised surface in this app keeps its state on the
/// model: the resolve lands from a task the view does not own, and a view that
/// held the field would have to be told about an answer that arrived for text it
/// may have already changed. Keeping both on one value makes "is this answer
/// still about what is typed" a comparison rather than a race.
struct JoinServerSheetState: Hashable, Sendable {
    /// Exactly what somebody typed or pasted, unmodified.
    ///
    /// Not the extracted code: the field shows what was entered, and rewriting
    /// somebody's text under their cursor while they type is the one thing a
    /// text field must never do.
    var input: String = ""

    /// What the resolve has to say about the code currently in `input`.
    var lookup: Lookup = .idle

    /// Whether a join is in flight. Separate from `lookup`, because the preview
    /// stays on screen while the join runs — it is what somebody is looking at
    /// while they wait.
    var isJoining = false

    /// Why the last join failed, if it did.
    var joinFailure: String?

    enum Lookup: Hashable, Sendable {
        /// Nothing typed, or nothing that looks like an invite yet.
        case idle
        /// A resolve is out for this code.
        case looking(String)
        case found(InvitePreview)
        /// The route refused. The sentence is the one shown; the code is kept so
        /// a stale failure can be told from a current one.
        case failed(code: String, message: String)
    }

    /// The code the sheet is currently about, if any.
    var code: String? { InvitePreview.code(in: input) }

    /// The preview on screen, if the answer is still about what is typed.
    ///
    /// **The comparison is the point.** An answer for a code somebody has since
    /// edited away is stale, and showing it is how a card for the wrong server
    /// ends up above a Join button.
    var preview: InvitePreview? {
        guard case .found(let preview) = lookup, preview.code == code else { return nil }
        return preview
    }

    var failureMessage: String? {
        if let joinFailure { return joinFailure }
        guard case .failed(let failedCode, let message) = lookup, failedCode == code else {
            return nil
        }
        return message
    }

    /// Whether the sheet is waiting on a resolve for what is typed now.
    var isLooking: Bool {
        guard case .looking(let pending) = lookup else { return false }
        return pending == code
    }

    /// Whether Join Server may be pressed.
    var canJoin: Bool { preview != nil && !isJoining }
}
