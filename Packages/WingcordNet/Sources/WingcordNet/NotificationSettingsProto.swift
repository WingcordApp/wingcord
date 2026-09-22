import Foundation
import WingcordCore

// MARK: - `NotificationSettings`, field 7 of `PreloadedUserSettings`
//
// **Field numbers out of Discord's compiled descriptor, defaults out of its own
// accessors.** The numbers live on `NotificationSwitch.field`, beside the
// sentence each one is drawn with, so a row and its field cannot drift apart.
// The defaults are the other half and they are not symmetric with the rest of
// this file's neighbours: every switch here reads `e?.value ?? true` in
// Discord's bundle, so an absent `BoolValue` means **on** — where the same
// absence in `MessagingPrivacy`'s age-restricted switches means off.
//
// `notifications.har` (2026-09-22) pinned the shape: seven PATCHes, each one
// switch, each body a single `notifications` message carrying a zero-length
// submessage for off and `{1: 1}` for on.
public enum NotificationSettingsProto {

    enum Top {
        static let notifications = 7
    }

    enum Field {
        static let showInApp = 1
        static let reactions = 7
        static let quietMode = 5
    }

    // MARK: Reading

    public static func decode(
        _ blob: Data
    ) -> (settings: NotificationSubscriptions, raw: Data?) {
        var value = NotificationSubscriptions()
        var raw: Data?
        var reader = ProtobufReader(blob)
        while let field = reader.next() {
            guard field.number == Top.notifications,
                  let data = reader.data(for: field) else { continue }
            raw = data
            decode(data, into: &value)
        }
        return (value, raw)
    }

    /// **The default belongs to an ABSENT field, never to a present one.**
    ///
    /// This is the trap, and a captured body caught it: `?? true` looks like it
    /// encodes "these default on", and it does not — it encodes "a field I could
    /// not read a payload out of is on". A `BoolValue` carrying `false` writes no
    /// payload at all, so a present, empty field and an absent one are the same
    /// bytes to that expression and opposite answers to the reader.
    ///
    /// So the loop only ever turns things **off**: it is walking the fields that
    /// are there, and every switch that is not there keeps the value
    /// `NotificationSubscriptions()` gave it — which is on, exactly as Discord's
    /// own accessors say.
    private static func decode(_ data: Data, into value: inout NotificationSubscriptions) {
        var reader = ProtobufReader(data)
        while let field = reader.next() {
            switch field.number {
            case Field.showInApp:
                value.showsInApp = (reader.wrappedValue(for: field) ?? 0) != 0
            case Field.quietMode:
                value.isQuiet = (reader.wrappedValue(for: field) ?? 0) != 0
            case Field.reactions:
                value.reactions = ReactionNotifications(rawValue: field.value) ?? .all
            default:
                guard let item = NotificationSwitch.allCases.first(
                    where: { $0.field == field.number }
                ) else { continue }
                value[item] = (reader.wrappedValue(for: field) ?? 0) != 0
            }
        }
    }

    // MARK: Writing

    public enum Change: Hashable, Sendable {
        case item(NotificationSwitch, Bool)
        case reactions(ReactionNotifications)
        case showInApp(Bool)
        case quietMode(Bool)
    }

    /// The body of `PATCH /users/@me/settings-proto/1` for one switch.
    ///
    /// The splice is `ActivityPrivacyProto.replacing`, for the reason it always
    /// is: `notifications` carries the account's notification-centre ack cursor
    /// and its focus-mode expiry, and a writer that re-serialised what it
    /// understood would reset both.
    public static func patch(applying change: Change, to raw: Data) -> String {
        var inner = ProtobufWriter()
        let field: Int
        switch change {
        case .item(let item, let isOn):
            field = item.field
            inner.message(field: field, ActivityPrivacyProto.boolValue(isOn))
        case .showInApp(let isOn):
            field = Field.showInApp
            inner.message(field: field, ActivityPrivacyProto.boolValue(isOn))
        case .quietMode(let isOn):
            field = Field.quietMode
            inner.message(field: field, ActivityPrivacyProto.boolValue(isOn))
        case .reactions(let scope):
            field = Field.reactions
            inner.varint(field: field, scope.rawValue)
        }
        let merged = ActivityPrivacyProto.replacing(field: field, with: inner.data, in: raw)
        var outer = ProtobufWriter()
        outer.message(field: Top.notifications, merged)
        return outer.base64
    }
}
