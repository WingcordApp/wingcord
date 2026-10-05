import Foundation
import WingcordCore
import WingcordNet

// MARK: - Writes from a thread's menu
//
// Discord's thread actions (`867455`) are not optimistic, apart from a pin: each
// PATCHes, and the thread changes when the answer lands — merged here exactly as
// a `THREAD_UPDATE` is, with the membership left alone.

extension SessionController {

    /// One write to a thread, with Discord's words when it is refused.
    ///
    /// - Parameter reopening: the write itself opens a closed thread, and a
    ///   refusal is the reopen's — "This server has reached the maximum number
    ///   of active posts…".
    /// - Parameter reopenFirst: the thread is closed and has to be opened
    ///   before anything else about it changes — Discord's
    ///   `unarchiveThreadIfNecessary`, ahead of tags and settings.
    func writeThread(
        _ edit: ThreadEdit,
        to threadID: ChannelID,
        isPost: Bool,
        reopening: Bool = false,
        reopenFirst: Bool = false
    ) {
        Task { [weak self] in
            guard let self else { return }
            if let refusal = await saveThread(
                edit, to: threadID, isPost: isPost, reopening: reopening, reopenFirst: reopenFirst
            ) {
                model.reportActionFailure(refusal)
            }
        }
    }

    /// `writeThread` for a caller that shows the refusal itself — the edit
    /// sheet, which keeps it on screen beside the fields. Nil once it lands.
    func saveThread(
        _ edit: ThreadEdit,
        to threadID: ChannelID,
        isPost: Bool,
        reopening: Bool = false,
        reopenFirst: Bool = false
    ) async -> String? {
        do {
            if reopenFirst {
                let reopened = try await rest.updateThread(threadID, ThreadEdit(archived: false))
                model.applyThreadUpsert(reopened, membership: nil)
            }
        } catch {
            Self.trace("reopen \(threadID) failed: \(Self.describe(error))")
            return Self.threadRefusal(error, isPost: isPost, reopening: true)
        }
        do {
            let answer = try await rest.updateThread(threadID, edit)
            model.applyThreadUpsert(answer, membership: nil)
            return nil
        } catch {
            Self.trace("thread edit \(threadID) failed: \(Self.describe(error))")
            return Self.threadRefusal(error, isPost: isPost, reopening: reopening)
        }
    }

    /// Lock or Unlock, in Discord's two steps: a closed thread is opened —
    /// unlocked in the same write, for an unlock — and the lock then closes it
    /// again, so it is left as closed as it was found.
    func writeThreadLock(_ locked: Bool, to threadID: ChannelID, wasArchived: Bool, isPost: Bool) {
        Task { [weak self] in
            guard let self else { return }
            if wasArchived {
                let reopen = ThreadEdit(archived: false, locked: locked ? nil : false)
                if let refusal = await saveThread(reopen, to: threadID, isPost: isPost, reopening: true) {
                    model.reportActionFailure(refusal)
                    return
                }
            }
            if let refusal = await saveThread(
                ThreadEdit(archived: wasArchived, locked: locked), to: threadID, isPost: isPost
            ) {
                model.reportActionFailure(refusal)
            }
        }
    }

    /// Pin Post or Unpin Post — the one optimistic write in the menu, as
    /// Discord's `updateFlags` is. A closed post is opened by its pin: a pinned
    /// post never closes itself.
    func writePin(_ pinned: Bool, post: Channel) {
        var flags = post.flags
        if pinned { flags.insert(.pinned) } else { flags.remove(.pinned) }
        let reopens = pinned && (post.threadMetadata?.isArchived ?? false)
        var shown = post
        shown.flags = flags
        model.applyThreadUpsert(shown, membership: nil)

        Task { [weak self] in
            guard let self else { return }
            do {
                let answer = try await rest.updateThread(
                    post.id, ThreadEdit(archived: reopens ? false : nil, flags: flags)
                )
                model.applyThreadUpsert(answer, membership: nil)
            } catch {
                Self.trace("pin post \(post.id) failed: \(Self.describe(error))")
                model.applyThreadUpsert(post, membership: nil)
                model.reportActionFailure(Self.threadRefusal(error, isPost: true, reopening: reopens))
            }
        }
    }

    /// Discord's words for a refused thread write (`867455`'s
    /// `unarchiveThread`): the server's caps on open threads, the rate limit,
    /// and — for a reopen only — the archive standing in the way. Anything else
    /// is Discord's general "An error occurred, please try again."
    static func threadRefusal(_ error: Error, isPost: Bool, reopening: Bool) -> String {
        let (status, code): (Int?, Int?) = switch error as? DiscordREST.Failure {
        case .forbidden(let code): (403, code)
        case .api(let status, let code, _): (status, code)
        default: (nil, nil)
        }
        switch (status, code) {
        case (_, 160006?):
            return isPost
                ? "This server has reached the maximum number of active posts. Free up space by archiving a post."
                : "This server has reached the maximum number of active threads. Free up space by archiving a thread."
        case (_, 160007?):
            return "This server has reached the maximum number of active announcement threads. "
                + "Free up space by archiving a thread."
        case (429?, _):
            return "You are being rate limited."
        case (403?, _) where reopening:
            return isPost ? "This post is archived." : "This thread is archived."
        default:
            return "An error occurred, please try again."
        }
    }
}
