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

    /// Discord's `getSetting()?.volume ?? 100`: no `voice_and_video` says
    /// nothing; one without `soundboard_settings` is 100; an empty
    /// `soundboard_settings` is 0, because proto3 writes no zero.
    @Test("Soundboard Volume reads as Discord reads it, and writes keeping its neighbours")
    func soundboardVolume() throws {
        #expect(SyncedPreferencesProto.decode(Data()).soundboardVolume == nil)

        // `voice_and_video` holding only an unrelated bool at field 2.
        var neighbour = ProtobufWriter()
        neighbour.varint(field: 2, 1)
        var blob = ProtobufWriter()
        blob.message(field: 5, neighbour.data)
        #expect(SyncedPreferencesProto.decode(blob.data).soundboardVolume == 100)

        let quieter = try #require(Data(base64Encoded: SyncedPreferencesProto.patch(
            applying: .soundboardVolume(42.5), to: blob.data
        )))
        #expect(SyncedPreferencesProto.decode(quieter).soundboardVolume == 42.5)
        // The neighbour survives the splice.
        var reader = ProtobufReader(quieter)
        var kept = false
        while let field = reader.next() {
            guard field.number == 5 else { continue }
            var inner = reader.reader(for: field)
            while let entry = inner.next() { if entry.number == 2 { kept = entry.value == 1 } }
        }
        #expect(kept)

        let silent = try #require(Data(base64Encoded: SyncedPreferencesProto.patch(
            applying: .soundboardVolume(0), to: quieter
        )))
        #expect(SyncedPreferencesProto.decode(silent).soundboardVolume == 0)
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

    /// Discord's `?.value ?? false`, and its write of `BoolValue{value}` either
    /// way — so off goes as a present empty wrapper.
    @Test("Always preview video reads as Discord reads it, and writes beside the soundboard")
    func alwaysPreviewVideo() throws {
        var volume = ProtobufWriter()
        volume.float(field: 1, 42.5)
        var voice = ProtobufWriter()
        voice.message(field: 9, volume.data)
        var blob = ProtobufWriter()
        blob.message(field: 5, voice.data)
        #expect(SyncedPreferencesProto.decode(blob.data).alwaysPreviewsVideo == false)

        let on = try #require(Data(base64Encoded: SyncedPreferencesProto.patch(
            applying: .alwaysPreviewsVideo(true), to: blob.data
        )))
        #expect(SyncedPreferencesProto.decode(on).alwaysPreviewsVideo == true)
        #expect(SyncedPreferencesProto.decode(on).soundboardVolume == 42.5)

        let off = try #require(Data(base64Encoded: SyncedPreferencesProto.patch(
            applying: .alwaysPreviewsVideo(false), to: on
        )))
        #expect(SyncedPreferencesProto.decode(off).alwaysPreviewsVideo == false)
        #expect(SyncedPreferencesProto.decode(off).soundboardVolume == 42.5)
    }
}
