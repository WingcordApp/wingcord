import Foundation
import WingcordCore

// MARK: - A toast on the overlay

/// One message worth telling somebody about while they are playing.
struct OverlayNotice: Identifiable, Hashable, Sendable {
    let id = UUID()
    var title: String
    var body: String
    var monogram: String
    var avatarURL: URL?
    var channelID: ChannelID
    var messageID: MessageID
    /// When it arrived, so the queue can retire it.
    var arrived = Date()
}

/// What the clip key just did.
struct ClipFeedback: Hashable, Sendable {
    var message: String
    var symbolName: String
    var isFailure: Bool

    static func saved(_ name: String) -> ClipFeedback {
        ClipFeedback(message: "Clip saved — \(name)", symbolName: "checkmark.circle.fill", isFailure: false)
    }

    static func screenshot(_ name: String) -> ClipFeedback {
        ClipFeedback(message: "Screenshot saved — \(name)", symbolName: "camera.fill", isFailure: false)
    }

    static func working() -> ClipFeedback {
        ClipFeedback(message: "Saving…", symbolName: "hourglass", isFailure: false)
    }

    static func failed(_ reason: String) -> ClipFeedback {
        ClipFeedback(message: reason, symbolName: "exclamationmark.triangle.fill", isFailure: true)
    }
}

// MARK: - The queue

extension OverlayController {

    /// How many toasts are on screen at once.
    ///
    /// **Three, and the oldest goes.** A queue that grows covers the game it is
    /// drawn over, and somebody in a busy server would lose the screen to
    /// Wingcord — which is the one thing an overlay must never do.
    static let noticeLimit = 3

    /// How long a toast stays.
    ///
    /// Longer than a system banner, because the reader is looking at a game and
    /// not at the corner of the screen.
    static let noticeLifetime: Duration = .seconds(7)

    /// Shows a toast, retiring the oldest if the queue is full.
    func show(_ notice: OverlayNotice) {
        guard isPresented, AppSettings.shared.overlayShowsNotifications else { return }
        notices.append(notice)
        if notices.count > Self.noticeLimit {
            // Dropping the oldest must drop its reply field with it, or the
            // hold outlives the toast it was holding and nothing else ever
            // retires.
            let dropped = notices.prefix(notices.count - Self.noticeLimit)
            for notice in dropped where replyingToNoticeID == notice.id { cancelReply() }
            notices.removeFirst(notices.count - Self.noticeLimit)
        }
        armRetirement(for: notice)
    }

    /// Starts one toast's clock.
    ///
    /// One task per notice rather than a repeating timer: a timer has to be
    /// owned, cancelled and reasoned about at teardown, and there is at most
    /// `noticeLimit` of these alive.
    ///
    /// **A toast being replied to does not retire, and does not poll either.**
    /// The clock still runs; when it fires against a held toast it files the id
    /// and stops, and releasing the hold arms a fresh one. That is the whole of
    /// the pause the reference draws as a button — expressed as a fact about
    /// the reply field rather than as a second control somebody has to press
    /// before they start typing.
    private func armRetirement(for notice: OverlayNotice) {
        Task { [weak self] in
            try? await Task.sleep(for: Self.noticeLifetime)
            guard let self else { return }
            guard !holdsNotice(notice.id) else {
                expiredNoticeIDs.insert(notice.id)
                return
            }
            dismiss(notice)
        }
    }

    /// Lets a held toast start dying again.
    ///
    /// **A fresh lifetime rather than an immediate dismissal**: somebody who
    /// opened a reply field and closed it again is still looking at the toast,
    /// and snatching it away at the moment they cancelled would read as the
    /// cancel having done something else.
    func releaseNoticeHold(_ id: UUID) {
        guard expiredNoticeIDs.remove(id) != nil else { return }
        guard let notice = notices.first(where: { $0.id == id }) else { return }
        armRetirement(for: notice)
    }

    func dismiss(_ notice: OverlayNotice) {
        if replyingToNoticeID == notice.id { cancelReply() }
        expiredNoticeIDs.remove(notice.id)
        notices.removeAll { $0.id == notice.id }
    }

    /// Puts a line under the clips widget, and takes it away again.
    func showClipFeedback(_ feedback: ClipFeedback) {
        clipFeedback = feedback
        let token = UUID()
        clipFeedbackToken = token
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(feedback.isFailure ? 6 : 3))
            guard let self, clipFeedbackToken == token else { return }
            clipFeedback = nil
        }
    }
}
