import Foundation
import Testing
@testable import WingcordCore
@testable import WingcordNet

/// Split view for threads and the ignored-profile warning, on the wire.
///
/// The `text_and_images` fixture is a captured body — the first `PATCH` of
/// `messaging permissions.har` (2026-09-22), the same bytes
/// `MessagingPrivacyTests` pins — so the splice is tested against everything a
/// real account keeps in that message, not against an empty one.
@Suite("Synced preferences")
struct SyncedPreferencesProtoTests {
    private static let capturedTextAndImages = Data(base64Encoded: """
        MnkqEzE0OTQ3MDUwOTYwMjg1ODYwNjRKAggBUgIIAVoCCAFiAggBagIIAXICCAF6AIIBAggBigEAmgECCAKiAQ\
        CqAQCyAQDKARMxMDU5MTM5MzQ1ODI0NjI4NzQ2ygESNTg3MzU1MzAxMDgzMzQ5MDAy6gEGCAEQAhgD
        """)!

    @Test("A text_and_images without use_thread_sidebar is split view on — Discord's ?? true")
    func defaultIsOn() {
        let delta = SyncedPreferencesProto.decode(Self.capturedTextAndImages)
        #expect(delta.opensThreadsInSplitView == true)
        #expect(delta.skipsIgnoredProfileWarning == nil)
    }

    @Test("A partial update without the message leaves the preference alone")
    func absentIsNil() {
        var preferences = SyncedPreferences(opensThreadsInSplitView: false, skipsIgnoredProfileWarning: true)
        preferences.apply(SyncedPreferencesProto.decode(Data()))
        #expect(preferences == SyncedPreferences(opensThreadsInSplitView: false, skipsIgnoredProfileWarning: true))
    }

    @Test("Switching split view off and on round-trips, every other byte kept")
    func splitViewRoundTrip() throws {
        let off = try #require(Data(base64Encoded: SyncedPreferencesProto.patch(
            applying: .opensThreadsInSplitView(false),
            to: Self.capturedTextAndImages
        )))
        #expect(SyncedPreferencesProto.decode(off).opensThreadsInSplitView == false)
        // The privacy page's own fields read exactly as before the write.
        #expect(MessagingPrivacyProto.decode(off).privacy == MessagingPrivacyProto.decode(Self.capturedTextAndImages).privacy)

        let on = try #require(Data(base64Encoded: SyncedPreferencesProto.patch(
            applying: .opensThreadsInSplitView(true),
            to: off
        )))
        #expect(SyncedPreferencesProto.decode(on).opensThreadsInSplitView == true)
        #expect(MessagingPrivacyProto.decode(on).privacy == MessagingPrivacyProto.decode(Self.capturedTextAndImages).privacy)
    }

    @Test("Don't show this again writes safety_settings field 2, keeping the preset")
    func skipWarning() throws {
        // `safety_settings` with only its preset set: field 21, `{ 1: 2 }`.
        var safety = ProtobufWriter()
        safety.varint(field: 1, 2)
        var blob = ProtobufWriter()
        blob.message(field: 21, safety.data)

        let patched = try #require(Data(base64Encoded: SyncedPreferencesProto.patch(
            applying: .skipsIgnoredProfileWarning(true),
            to: blob.data
        )))
        #expect(SyncedPreferencesProto.decode(patched).skipsIgnoredProfileWarning == true)

        var reader = ProtobufReader(patched)
        var preset: UInt64?
        while let field = reader.next() {
            guard field.number == 21 else { continue }
            var inner = reader.reader(for: field)
            while let entry = inner.next() {
                if entry.number == 1 { preset = entry.value }
            }
        }
        #expect(preset == 2)
    }
}
