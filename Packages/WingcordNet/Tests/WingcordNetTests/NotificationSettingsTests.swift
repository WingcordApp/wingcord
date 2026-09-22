import Foundation
import Testing
@testable import WingcordCore
@testable import WingcordNet

/// The account's own notification preferences, on the wire.
///
/// **Captured bodies, not constructed ones** — `INVARIANTS.md` §2.6. These are
/// verbatim `PATCH /users/@me/settings-proto/1` bodies out of
/// `notifications.har` (2026-09-22), taken one switch at a time.
@Suite("Notification subscriptions")
struct NotificationSettingsTests {

    /// The second captured PATCH, after three switches went off.
    private static let offPatch = "OhASABlIEAQPW1vPEHIAygEA"

    /// The sixth, after "Friends update their profile" came back on — the same
    /// field as the one before it, carrying `{1: 1}` instead of nothing.
    private static let onPatch = "OhoSABlIEAQPW1vPEGIAcgCCAQIIAbIBAMoBAA=="

    /// The last, which carries several at once and both spellings of a
    /// `BoolValue` in one message.
    private static let mixedPatch =
        "KhgqADIDCNgEOgIIAUICCAFKBQ0AAMhCUgA6IBIAGUgQBA9bW88QYgIIAXICCAGCAQIIAbIBAggBygEA"

    private func decode(_ base64: String) -> (
        settings: NotificationSubscriptions, raw: Data?
    ) {
        NotificationSettingsProto.decode(Data(base64Encoded: base64) ?? Data())
    }

    @Test("An absent switch is ON, which is the opposite of its neighbours")
    func absenceMeansOn() {
        // Read out of Discord's own accessors: every one of these is
        // `e?.value ?? true`. The same absence in `MessagingPrivacy`'s
        // age-restricted switches means off, which is exactly why the default
        // cannot be assumed once and reused.
        let value = decode("").settings
        for item in NotificationSwitch.allCases {
            #expect(value[item], "\(item.rawValue) should default on")
        }
        #expect(value.showsInApp)
        // The one exception.
        #expect(!value.isQuiet)
    }

    @Test("A zero-length submessage is a switch turned off")
    func emptyMeansOff() {
        let value = decode(Self.offPatch).settings
        #expect(!value[.letFriendsKnowIComeOnline])
        #expect(!value[.friendAnniversary])
        // …and the ones that body says nothing about are still on.
        #expect(value[.friendsComeOnline])
        #expect(value[.upcomingServerEvents])
    }

    @Test("The same field carrying {1: 1} is the switch back on")
    func payloadMeansOn() {
        // Field 16 is `enable_profile_updates_notifications`. In the fifth body
        // it is `ggEA` — empty — and in the sixth it is `ggECCAE`.
        #expect(decode(Self.onPatch).settings[.profileUpdates])
        #expect(!decode(Self.offPatch).settings[.friendAnniversary])
    }

    @Test("A body carrying several switches reads every one of them")
    func mixedBody() {
        let value = decode(Self.mixedPatch).settings
        #expect(value[.friendsComeOnline])
        #expect(value[.friendAnniversary])
        #expect(value[.profileUpdates])
        #expect(value[.upcomingServerEvents])
    }

    @Test("A write keeps the bytes it did not come for")
    func writePreservesTheRest() throws {
        // `notifications` carries the account's notification-centre ack cursor
        // and its focus-mode expiry. A writer that re-serialised what it
        // understood would reset both, and nothing would say so.
        let (_, raw) = decode(Self.mixedPatch)
        let before = try #require(raw)
        let patch = NotificationSettingsProto.patch(
            applying: .item(.friendsComeOnline, false), to: before
        )
        let after = decode(patch)
        #expect(!after.settings[.friendsComeOnline])
        #expect(after.settings[.friendAnniversary])
        #expect(after.settings[.profileUpdates])

        // The ack cursor — field 3, a bare fixed64 this client never reads — is
        // still in the bytes that came back.
        var reader = ProtobufReader(try #require(after.raw))
        var sawCursor = false
        while let field = reader.next() {
            if field.number == 3 { sawCursor = true }
        }
        #expect(sawCursor, "the notification-centre cursor was dropped")
    }

    @Test("The reaction scope is a bare enum and round-trips")
    func reactionScope() {
        #expect(decode("").settings.reactions == .all)
        for scope in ReactionNotifications.allCases {
            let patch = NotificationSettingsProto.patch(applying: .reactions(scope), to: Data())
            #expect(decode(patch).settings.reactions == scope)
        }
    }

    @Test("Every switch has its own field number")
    func fieldsAreDistinct() {
        // Two rows sharing a number is a page where one switch moves another,
        // and it is invisible until somebody notices the wrong thing changed.
        let fields = Set(NotificationSwitch.allCases.map(\.field))
        #expect(fields.count == NotificationSwitch.allCases.count)
        #expect(NotificationSwitch.incoming.count + NotificationSwitch.outgoing.count
            == NotificationSwitch.allCases.count)
    }
}
