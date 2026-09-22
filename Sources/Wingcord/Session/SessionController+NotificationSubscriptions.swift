import Foundation
import WingcordCore
import WingcordNet

// MARK: - The account's notification preferences

extension SessionController {

    /// Loads them when the pane opens, and once.
    func loadNotificationSubscriptions() async {
        guard model.notificationSubscriptionsRaw == nil else { return }
        do {
            let fetched = try await rest.notificationSubscriptions()
            model.notificationSubscriptions = fetched.settings
            model.notificationSubscriptionsRaw = fetched.raw ?? Data()
        } catch {
            Self.trace("notification settings load failed: \(Self.describe(error))")
        }
    }

    /// Sends one switch.
    ///
    /// Optimistic and restored on refusal, exactly as the messaging-permissions
    /// page is — and inert until the bytes a patch splices into have arrived,
    /// because `notifications` carries the account's notification-centre cursor
    /// and its focus-mode expiry and a blind write would reset both.
    func writeNotificationSubscription(
        _ change: NotificationSettingsProto.Change,
        restoring previous: NotificationSubscriptions
    ) {
        guard let raw = model.notificationSubscriptionsRaw else {
            model.notificationSubscriptions = previous
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await rest.setNotificationSubscription(change, preserving: raw)
                // Re-read: the write is a merge, and the next splice has to go
                // into its result rather than into the bytes from before it.
                let fetched = try await rest.notificationSubscriptions()
                model.notificationSubscriptions = fetched.settings
                model.notificationSubscriptionsRaw = fetched.raw ?? Data()
            } catch {
                Self.trace("notification settings write failed: \(Self.describe(error))")
                model.notificationSubscriptions = previous
            }
        }
    }
}
