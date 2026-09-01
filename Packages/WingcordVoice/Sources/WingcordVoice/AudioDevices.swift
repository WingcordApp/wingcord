import AVFoundation
import CoreAudio
import Foundation

// MARK: - What the Mac has to listen and speak with
//
// CoreAudio's device list, read through the HAL rather than through
// `AVCaptureDevice`. `AVCaptureDevice` knows about microphones and nothing at
// all about outputs, so an app that uses it for the input picker needs a second
// mechanism for the output picker — and then the two disagree about which
// aggregate device is which.

public struct AudioDevice: Hashable, Sendable, Identifiable {
    public var id: AudioDeviceID
    public var name: String
    /// The manufacturer's own id. Survives a rename, an unplug and a reboot,
    /// which the numeric `AudioDeviceID` does not — so this is what a preference
    /// is stored as.
    public var uniqueID: String
    public var isInput: Bool
    public var isOutput: Bool
    public var isDefault: Bool
}

public enum AudioDeviceCatalog {

    /// Every device that can record, plus a marker for the system default.
    public static func inputs() -> [AudioDevice] { devices(input: true) }
    public static func outputs() -> [AudioDevice] { devices(input: false) }

    /// Resolves a stored `uniqueID` back to the numeric id the audio unit wants.
    ///
    /// Returns nil when the device is gone, which the caller must treat as
    /// "fall back to the system default" rather than as an error: unplugging a
    /// headset mid-call is ordinary, and a call that ends because of it is a bug.
    public static func device(uniqueID: String, input: Bool) -> AudioDevice? {
        devices(input: input).first { $0.uniqueID == uniqueID }
    }

    public static func systemDefault(input: Bool) -> AudioDevice? {
        devices(input: input).first { $0.isDefault }
    }

    private static func devices(input: Bool) -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }

        let defaultID = defaultDeviceID(input: input)
        return ids.compactMap { id in
            guard channelCount(of: id, input: input) > 0 else { return nil }
            guard let name = stringProperty(kAudioObjectPropertyName, of: id) else { return nil }
            return AudioDevice(
                id: id,
                name: name,
                uniqueID: stringProperty(kAudioDevicePropertyDeviceUID, of: id) ?? String(id),
                isInput: input,
                isOutput: !input,
                isDefault: id == defaultID
            )
        }
    }

    private static func defaultDeviceID(input: Bool) -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: input
                ? kAudioHardwarePropertyDefaultInputDevice
                : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id
        )
        return id
    }

    /// How many channels a device has **in one direction**.
    ///
    /// This is the only reliable way to tell an input from an output: a device
    /// object exists for both scopes whether or not it has any streams there,
    /// so listing "every device" and calling them all microphones puts the
    /// speakers in the input picker.
    private static func channelCount(of id: AudioDeviceID, input: Bool) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer) == noErr else {
            return 0
        }
        let list = UnsafeMutableAudioBufferListPointer(
            buffer.assumingMemoryBound(to: AudioBufferList.self)
        )
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(
        _ selector: AudioObjectPropertySelector,
        of id: AudioDeviceID
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }
}
