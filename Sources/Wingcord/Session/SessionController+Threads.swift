import Foundation
import WingcordCore
import WingcordNet

// MARK: - The network side of threads and forum boards
//
// Same division as everywhere else in this layer: the store decides and applies,
// this performs and reports back. Every optimistic write here carries the value
// it replaced, so a refusal restores exactly what was there rather than a guess
// at what it should be.

extension SessionController {

    // MARK: Boards

    /// Fetches one page of a forum's posts.
    ///
    /// - Parameter replacing: whether this page starts the list over. A filter
    ///   change replaces; scrolling appends.
    func loadForumPage(
        _ channelID: ChannelID,
        query: ForumQuery,
        offset: Int,
        replacing: Bool
    ) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await rest.forumPosts(
                    in: channelID, query: query, offset: offset
                )
                // The reader may have changed the filter while this was in
                // flight. Applying it then would splice posts from the old
                // question into the new list — and the board has already been
                // cleared for the new one, so the rows would simply be wrong.
                guard model.forumBoards[channelID]?.query.matchesFetch(query) ?? true else {
                    return
                }
                model.applyForumPage(page, in: channelID, replacing: replacing)
            } catch {
                Self.trace("forum page \(channelID) failed: \(Self.describe(error))")
                model.applyForumPageFailure(in: channelID)
            }
        }
    }

    /// Searches a channel's threads by name.
    ///
    /// `async` rather than fire-and-forget, unlike the rest of this file: the
    /// caller is a debounce task that has already waited, and awaiting here is
    /// what lets its cancellation reach the request.
    func searchThreads(in channelID: ChannelID, name: String) async {
        do {
            let page = try await rest.searchThreads(in: channelID, name: name)
            guard !Task.isCancelled else { return }
            model.applyThreadSearch(page, phrase: name, in: channelID)
        } catch {
            guard !Task.isCancelled else { return }
            Self.trace("thread search \(channelID) failed: \(Self.describe(error))")
            model.applyThreadSearchFailure(phrase: name)
        }
    }

    /// Fills in the opening message and author for a batch of posts.
    ///
    /// A failure is not surfaced: the rows it would have filled keep their
    /// title, tags and counts, which is most of what a row is. Marking the
    /// board failed over a missing preview line would put a retry banner over a
    /// list that is perfectly readable.
    func loadForumPostDetails(_ postIDs: [ChannelID], in channelID: ChannelID) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let details = try await rest.forumPostData(
                    in: channelID, threadIDs: postIDs
                )
                model.applyForumPostDetails(details, in: channelID)
            } catch {
                Self.trace("post-data \(channelID) failed: \(Self.describe(error))")
            }
        }
    }

    /// Opens a post in a forum.
    ///
    /// A refusal is surfaced on the board rather than swallowed: the sheet has
    /// already closed, so a silent failure is a post the reader believes they
    /// wrote.
    func createForumPost(
        in channelID: ChannelID,
        name: String,
        content: String,
        tags: [ForumTagID],
        autoArchiveMinutes: Int
    ) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let post = try await rest.createForumPost(
                    in: channelID,
                    name: name,
                    content: content,
                    tags: tags,
                    autoArchiveMinutes: autoArchiveMinutes,
                    nonce: Self.nonce()
                )
                model.applyCreatedForumPost(post, in: channelID)
            } catch {
                Self.trace("forum post in \(channelID) failed: \(Self.describe(error))")
                model.applyForumPageFailure(in: channelID)
            }
        }
    }

    // MARK: Membership

    func writeThreadMembership(
        _ followed: Bool,
        threadID: ChannelID,
        location: String,
        previous: ThreadMember?
    ) {
        Task { [weak self] in
            guard let self else { return }
            do {
                if followed {
                    try await rest.joinThread(threadID, location: location)
                } else {
                    try await rest.leaveThread(threadID, location: location)
                }
            } catch {
                Self.trace("thread follow \(threadID) failed: \(Self.describe(error))")
                model.restoreThreadMembership(previous, threadID: threadID)
            }
        }
    }

    func writeThreadNotification(
        _ setting: ThreadNotification,
        threadID: ChannelID,
        joinFirst: Bool,
        previous: ThreadMember?
    ) {
        Task { [weak self] in
            guard let self else { return }
            guard let userID = model.currentUserID else { return }
            do {
                // **The join has to land first.** The setting lives on a member
                // row, and Discord has none to PATCH until the account is in the
                // thread — which is why its own client sends the join with
                // `location=Change Notification Settings`.
                if joinFirst {
                    try await rest.joinThread(threadID, location: "Change Notification Settings")
                }
                let member = try await rest.setThreadNotification(
                    setting, in: threadID, userID: userID
                )
                model.applyThreadMembership(member)
            } catch {
                Self.trace("thread notify \(threadID) failed: \(Self.describe(error))")
                model.restoreThreadMembership(previous, threadID: threadID)
            }
        }
    }

    func writeThreadMute(
        _ duration: MuteDuration?,
        threadID: ChannelID,
        joinFirst: Bool,
        previous: ThreadMember?
    ) {
        Task { [weak self] in
            guard let self else { return }
            guard let userID = model.currentUserID else { return }
            do {
                if joinFirst {
                    try await rest.joinThread(threadID, location: "Change Notification Settings")
                }
                let member = try await rest.setThreadMute(
                    duration, in: threadID, userID: userID
                )
                model.applyThreadMembership(member)
            } catch {
                Self.trace("thread mute \(threadID) failed: \(Self.describe(error))")
                model.restoreThreadMembership(previous, threadID: threadID)
            }
        }
    }
}

extension AppModel {
    /// Puts back exactly what an optimistic thread write replaced.
    ///
    /// A nil `previous` means there was no membership, which is what "not
    /// following" *is* — so this removes rather than writing an empty one.
    func restoreThreadMembership(_ previous: ThreadMember?, threadID: ChannelID) {
        threadMemberships[threadID] = previous
        threadRevision &+= 1
        sidebarRevision &+= 1
    }
}
