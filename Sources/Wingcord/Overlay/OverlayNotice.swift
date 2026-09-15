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
        if notices.count > Self.noticeLimit { notices.removeFirst(notices.count - Self.noticeLimit) }
        // One task per notice rather than a repeating timer: a timer has to be
        // owned, cancelled and reasoned about at teardown, and there is at most
        // `noticeLimit` of these alive.
        Task { [weak self] in
            try? await Task.sleep(for: Self.noticeLifetime)
            self?.dismiss(notice)
        }
    }

    func dismiss(_ notice: OverlayNotice) {
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
