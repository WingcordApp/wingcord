import AVFoundation
import Foundation
import Testing
@testable import Wingcord

/// The clips a call plays.
///
/// **A missing or unreadable sound is silent, and silence is what this feature
/// looks like when it is working.** So every case is resolved to a real file and
/// decoded here — a resource dropped from the manifest, a rename, or a format
/// the platform stopped reading all fail loudly instead of once, quietly, on
/// somebody's machine.
@Suite("Voice sounds")
struct VoiceSoundTests {

    @Test("Every sound is in the bundle", arguments: VoiceSound.allCases)
    func everySoundIsPresent(_ sound: VoiceSound) throws {
        let url = try #require(sound.url, "no file for \(sound.rawValue)")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("Every sound decodes to audible stereo at the mixer's rate",
          arguments: VoiceSound.allCases)
    func everySoundDecodes(_ sound: VoiceSound) throws {
        let url = try #require(sound.url)
        let decoded = try #require(
            VoiceSoundPlayer.decode(url), "\(sound.rawValue) would not decode"
        )
        // The one format both engines take. Anything else means something
        // downstream is converting per play.
        #expect(decoded.buffer.format.sampleRate == 48_000)
        #expect(decoded.buffer.format.channelCount == 2)
        #expect(decoded.buffer.frameLength > 0)
        // Interleaved stereo, so the sample count is two per frame.
        #expect(decoded.samples.count == Int(decoded.buffer.frameLength) * 2)
        // **Not silence.** A file that decodes to zeroes passes every other
        // check here and plays nothing.
        #expect(decoded.samples.contains { abs($0) > 0.01 })
    }

    /// Under three seconds each. A blip that outlasts the act it reports is a
    /// blip still playing when the next one fires.
    @Test("No sound outlasts the thing it reports", arguments: VoiceSound.allCases)
    func soundsAreShort(_ sound: VoiceSound) throws {
        let url = try #require(sound.url)
        let decoded = try #require(VoiceSoundPlayer.decode(url))
        let seconds = Double(decoded.buffer.frameLength) / decoded.buffer.format.sampleRate
        #expect(seconds > 0.1)
        #expect(seconds < 3.0)
    }

    @Test("The ringback is the only one that loops")
    func onlyTheRingbackLoops() {
        #expect(VoiceSound.allCases.filter(\.loops) == [.outgoingCall])
    }

    /// Every sound sits under the conversation it interrupts, and the ringback
    /// — the only one that plays into silence — is the loud one.
    @Test("Levels are bounded, and the ringback leads")
    func levelsAreSane() {
        for sound in VoiceSound.allCases {
            #expect(sound.volume > 0 && sound.volume <= 1)
            if sound != .outgoingCall {
                #expect(sound.volume < VoiceSound.outgoingCall.volume)
            }
        }
    }
}
