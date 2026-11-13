import AppKit
import Foundation
import UserNotifications
import WingcordCore

/// The one place this app speaks to Notification Center.
///
/// **Everything about *whether* to interrupt is decided elsewhere** — in
/// `NotificationPolicy`, which is pure and testable and has no idea this file
/// exists. What is here is the machinery: authorisation, posting, coalescing,
/// and turning a click into a place in the app.
///
/// **The delegate is the whole reason this is an object.** A banner's tap
/// arrives on `UNUserNotificationCenterDelegate`, which has to be an
/// `NSObject` set on the shared centre before the first notification is posted;
/// there is nowhere else that callback can go, and a delegate installed after a
/// banner is already on screen misses it.
@MainActor
final class MessageNotifier: NSObject {

    /// Where a tapped notification sends the reader. Set by the window root,
    /// which is the only thing that can navigate.
    ///
    /// `@ObservationIgnored`-shaped by construction: this object is not
    /// observable, and the closure is machinery rather than state.
    var open: ((ChannelID, MessageID) -> Void)?

    /// Whether the reader has been asked yet.
    ///
    /// **Asked once, lazily, and never at launch.** A permission sheet on the
    /// first run of an app somebody has not yet signed into is a question about
    /// something they have not seen; this asks the first time there is genuinely
    /// something to tell them about.
    private var hasRequestedAuthorization = false
    private var isAuthorized = false

    /// How many notifications one channel may have on screen at once.
    ///
    /// **Coalesced by replacing, not by counting.** Twenty messages in one
    /// channel is one thing that happened — somebody is talking — and twenty
    /// banners is the behaviour that makes people turn notifications off. Each
    /// channel has one identifier, so a second message in it *replaces* the
    /// first rather than stacking beside it, and the body says how many.
    private var pending: [ChannelID: Int] = [:]

    /// Notification Center, or nil where there is none to speak to.
    ///
    /// **`UNUserNotificationCenter.current()` TRAPS in a process with no bundle
    /// identifier**, with `bundleProxyForCurrentProcess is nil` — not a nil
    /// return and not a thrown error, an uncaught `NSException`. A test process
    /// is exactly that process, and so is anything run through `swift run`. So
    /// the centre is resolved once, behind the check that decides it, and every
    /// path here is nil-tolerant.
    ///
    /// This is not test scaffolding: the app cannot post a notification without
    /// a bundle either, and a client that crashed rather than staying quiet
    /// would be worse in every environment where this is nil.
    private let centre: UNUserNotificationCenter?

    override init() {
        centre = Bundle.main.bundleIdentifier == nil ? nil : .current()
        super.init()
        centre?.delegate = self
    }

    // MARK: Asking

    /// Asks, once, and remembers the answer.
    ///
    /// A refusal is final and is not re-asked: macOS shows the sheet once per
    /// install, and a client that called this again would silently do nothing
    /// while looking like it was trying.
    func requestAuthorizationIfNeeded() async {
        guard !hasRequestedAuthorization, let centre else { return }
        hasRequestedAuthorization = true
        do {
            isAuthorized = try await centre.requestAuthorization(options: [.alert, .sound, .badge])
            Log.info(.notify, "authorised: \(isAuthorized)")
        } catch {
            // A refusal is not a failure worth telling anybody about — they
            // refused. The app works; it simply stays quiet.
            isAuthorized = false
            Log.info(.notify, "authorisation failed: \(error)")
        }
    }

    // MARK: Posting

    /// Puts one message on screen as a banner.
    ///
    /// - Parameters:
    ///   - title: who and where — "alex in #general", or just the person in a
    ///     conversation.
    ///   - body: what they said, already folded to plain text.
    ///   - playsSound: the reader's own preference; the policy above decided
    ///     *whether*, this decides *how loudly*.
    func post(
        title: String,
        subtitle: String?,
        body: String,
        channelID: ChannelID,
        messageID: MessageID,
        playsSound: Bool
    ) {
        guard isAuthorized, let centre else { return }

        let count = (pending[channelID] ?? 0) + 1
        pending[channelID] = count

        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle, !subtitle.isEmpty { content.subtitle = subtitle }
        // **The newest message, with a count rather than a list.** A banner is
        // read in a second and a transcript of six lines in it is a wall; the
        // number is what says "there is more", and opening it is what shows the
        // rest.
        content.body = count > 1 ? "\(body)\n\(count) new messages" : body
        content.sound = playsSound ? .default : nil
        content.userInfo = [
            Self.channelKey: String(channelID.rawValue),
            Self.messageKey: String(messageID.rawValue),
        ]
        // Groups the channel's banners in Notification Centre under one heading,
        // which is what makes the replacement above read as an update rather
        // than as a banner that vanished.
        content.threadIdentifier = String(channelID.rawValue)

        // **The identifier is the CHANNEL's, not the message's.** That is the
        // coalescing: posting with an identifier already on screen replaces it.
        centre.add(
            UNNotificationRequest(
                identifier: Self.identifier(for: channelID),
                content: content,
                trigger: nil
            )
        )
    }

    /// Takes a channel's banners down.
    ///
    /// Called when the reader opens it: a notification about a channel they are
    /// now reading is chrome describing something they have already done.
    func clear(_ channelID: ChannelID) {
        guard pending.removeValue(forKey: channelID) != nil, let centre else { return }
        let identifier = Self.identifier(for: channelID)
        centre.removeDeliveredNotifications(withIdentifiers: [identifier])
        centre.removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    /// Everything, on sign-out. The banners belong to the account that earned
    /// them.
    func clearAll() {
        pending.removeAll(keepingCapacity: false)
        centre?.removeAllDeliveredNotifications()
        centre?.removeAllPendingNotificationRequests()
    }

    private static func identifier(for channelID: ChannelID) -> String {
        "channel.\(channelID.rawValue)"
    }

    // `nonisolated` because the delegate reads them off the main actor, before
    // hopping. `INVARIANTS.md` §5.16: `nonisolated` belongs on the declaration,
    // not on a hop invented at the call site.
    nonisolated private static let channelKey = "channel"
    nonisolated private static let messageKey = "message"
}

// MARK: - What a click means

extension MessageNotifier: UNUserNotificationCenterDelegate {

    /// A banner while the app is frontmost.
    ///
    /// **Never shown, and that is deliberate rather than an omission.** The
    /// policy has already decided the reader is not looking at *this channel* —
    /// but if the app is frontmost they are looking at the app, and the sidebar
    /// is already carrying the unread. A banner over a window that is showing
    /// the same fact twice is the interruption people mean when they say an app
    /// is noisy. The sound still plays, because that is the part that carries
    /// across a window they are not looking directly at.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        await MainActor.run { NSApp.isActive ? [.sound] : [.banner, .sound, .list] }
    }

    /// The reader pressed it.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        guard let channelRaw = info[Self.channelKey] as? String,
              let channelValue = UInt64(channelRaw),
              let messageRaw = info[Self.messageKey] as? String,
              let messageValue = UInt64(messageRaw)
        else { return }

        await MainActor.run {
            // The window first: a jump into a hidden window is a jump nobody
            // sees, and macOS does not raise an app because one of its
            // notifications was pressed.
            NSApp.activate(ignoringOtherApps: true)
            open?(ChannelID(rawValue: channelValue), MessageID(rawValue: messageValue))
        }
    }
}
