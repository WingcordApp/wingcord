import Foundation
import Testing
import WingcordCore
import WingcordVoice
@testable import Wingcord

/// Discord's Input Sensitivity and the old setting it replaced, its input
/// profiles, and its Go Live and Stream Attenuation choices.
///
/// **Serialized and on its own defaults**, because these write to a suite and
/// read it back; run in parallel against `.standard` they would fight each other
/// and the reader's real settings.
@MainActor
@Suite("Voice settings", .serialized)
struct VoiceSettingsTests {

    private func defaults(_ seed: [String: Any] = [:]) -> UserDefaults {
        let suite = UserDefaults(suiteName: "wingcord.tests.\(UUID().uuidString)")!
        for (key, value) in seed { suite.set(value, forKey: key) }
        return suite
    }

    @Test("A reader who never chose gets Discord's: automatic, with the line at −60 dB")
    func defaultsAreDiscords() {
        let settings = AppSettings(defaults: defaults())
        #expect(settings.automaticInputSensitivity)
        #expect(settings.voiceActivityThreshold == -60)
        #expect(settings.resolvedInputMode == .voiceActivity(.init(isAutomatic: true, threshold: -60)))
    }

    /// Decision 4. The old line was linear — 0.03 by default — and survives as
    /// the same line on Discord's scale, written once under its new key.
    @Test("The old linear line is converted once to decibels")
    func migratesTheLinearLine() throws {
        let suite = defaults(["voice.activityThreshold": 0.03])
        let settings = AppSettings(defaults: suite)
        #expect(abs(settings.voiceActivityThreshold - -30.46) < 0.01)
        #expect(suite.object(forKey: "voice.activityThreshold") == nil, "the old key is gone")
        let stored = try #require(suite.object(forKey: "voice.activityThresholdDecibels") as? Double)
        #expect(abs(stored - -30.46) < 0.01, "and the new one is written, not left to an observer")
        #expect(abs(AppSettings(defaults: suite).voiceActivityThreshold - -30.46) < 0.01)
    }

    @Test("The line stays on Discord's scale, −100 to 0")
    func clamps() {
        let settings = AppSettings(defaults: defaults())
        settings.voiceActivityThreshold = 12
        #expect(settings.voiceActivityThreshold == 0)
        settings.voiceActivityThreshold = -400
        #expect(settings.voiceActivityThreshold == -100)
    }

    /// Discord's profiles are overrides: Studio is the 48 kHz path with no
    /// processing and voice activity at −84 dB whatever was chosen; Voice
    /// Isolation is the processor with the line found for you; Custom is the
    /// reader's own switches untouched.
    @Test("Each input profile resolves as Discord's does")
    func profiles() {
        let settings = AppSettings(defaults: defaults())
        settings.inputMode = .pushToTalk
        settings.pushToTalkKey = nil
        settings.echoCancellation = false
        settings.automaticInputSensitivity = false

        settings.inputProfile = .studio
        #expect(settings.resolvedProcessing == .init(echoCancellation: false, automaticGainControl: false))
        #expect(settings.resolvedInputMode == .voiceActivity(.init(isAutomatic: false, threshold: -84)))

        settings.inputProfile = .voiceIsolation
        #expect(settings.resolvedProcessing == .init(echoCancellation: true, automaticGainControl: true))
        #expect(settings.resolvedInputMode == .voiceActivity(.init(isAutomatic: true, threshold: -60)))

        settings.inputProfile = .custom
        #expect(settings.resolvedProcessing == .init(echoCancellation: false, automaticGainControl: true))
        #expect(settings.resolvedInputMode == .voiceActivity(.init(isAutomatic: false, threshold: -60)))
    }

    @Test("A reader who never chose is on Custom, with echo cancellation and gain control on")
    func profileDefaults() {
        let settings = AppSettings(defaults: defaults())
        #expect(settings.inputProfile == .custom)
        #expect(settings.resolvedProcessing == .init())
    }

    /// Discord's `ApplicationStreamingSettingsStore`: 720p, 30 frames a second,
    /// the sound shared — and kept from one stream to the next.
    @Test("Go Live starts at Discord's 720p30 with sound, and remembers a choice")
    func goLiveSettings() {
        let suite = defaults()
        let settings = AppSettings(defaults: suite)
        #expect(settings.goLive == GoLiveSettings(resolution: .p720, frameRate: .fps30, sharesAudio: true))

        settings.goLive = GoLiveSettings(resolution: .p1080, frameRate: .fps60, sharesAudio: false)
        #expect(AppSettings(defaults: suite).goLive == settings.goLive)
    }

    /// The old toggle's key is Share Audio's, so a reader who had turned the
    /// sound off still has it off.
    @Test("Share Audio carries over the old toggle's choice")
    func shareAudioCarriesOver() {
        let settings = AppSettings(defaults: defaults(["voice.sharesSystemAudio": false]))
        #expect(!settings.goLive.sharesAudio)
    }

    @Test("Stream Attenuation is on at 50, and off means none")
    func streamAttenuation() {
        let settings = AppSettings(defaults: defaults())
        #expect(settings.streamAttenuation)
        #expect(settings.streamAttenuationStrength == 50)
        #expect(settings.resolvedStreamAttenuation == 0.5)

        settings.streamAttenuationStrength = 130
        #expect(settings.streamAttenuationStrength == 100, "Discord's scale stops at 100")
        settings.streamAttenuation = false
        #expect(settings.resolvedStreamAttenuation == nil)
    }
}
