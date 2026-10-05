import Foundation
import WingcordCore

/// `SyncedPreferences` on the wire: two fields of `PreloadedUserSettings`, read
/// out of Discord's compiled descriptors (`TextAndImagesSettings`,
/// `SafetySettings`) rather than recalled.
public enum SyncedPreferencesProto {
    enum Top {
        static let textAndImages = 6
        static let safetySettings = 21
    }
    /// `use_thread_sidebar`, a `BoolValue` — Discord reads it `?.value ?? true`,
    /// so an absent wrapper is on and a present empty one is off.
    static let useThreadSidebar = 3
    /// `ignore_profile_speedbump_disabled`, a **bare** bool, absent when false.
    static let ignoreProfileSpeedbumpDisabled = 2

    public enum Change: Sendable {
        case opensThreadsInSplitView(Bool)
        case skipsIgnoredProfileWarning(Bool)
    }

    /// What a blob says, each preference nil where its message is absent — see
    /// `SyncedPreferences.Delta`.
    public static func decode(_ data: Data) -> SyncedPreferences.Delta {
        var delta = SyncedPreferences.Delta()
        var reader = ProtobufReader(data)
        while let field = reader.next() {
            switch field.number {
            case Top.textAndImages where field.wireType == 2:
                var opens = true
                var inner = reader.reader(for: field)
                while let entry = inner.next() {
                    guard entry.number == useThreadSidebar, entry.wireType == 2 else { continue }
                    var wrapper = inner.reader(for: entry)
                    var value = false
                    while let bit = wrapper.next() {
                        guard bit.number == 1, bit.wireType == 0 else { continue }
                        value = bit.value != 0
                    }
                    opens = value
                }
                delta.opensThreadsInSplitView = opens
            case Top.safetySettings where field.wireType == 2:
                var skips = false
                var inner = reader.reader(for: field)
                while let entry = inner.next() {
                    guard entry.number == ignoreProfileSpeedbumpDisabled, entry.wireType == 0 else { continue }
                    skips = entry.value != 0
                }
                delta.skipsIgnoredProfileWarning = skips
            default:
                break
            }
        }
        return delta
    }

    /// The body of `PATCH /users/@me/settings-proto/1` for one change: the one
    /// top-level message it lives in, **every other byte of it as it came** —
    /// Discord's writer replaces a top-level field whole, and `text_and_images`
    /// alone holds a reader's keyword filters, their collapsed emoji sections
    /// and a dozen more. See `ActivityPrivacyProto.replacing`.
    ///
    /// - Parameter blob: the whole settings blob, fetched just before.
    static func patch(applying change: Change, to blob: Data) -> String {
        let top: Int
        let field: Int
        let encoded: Data?
        switch change {
        case .opensThreadsInSplitView(let opens):
            top = Top.textAndImages
            field = useThreadSidebar
            var writer = ProtobufWriter()
            // An empty wrapper for off — proto3 writes no false — and that
            // present-but-empty wrapper is what Discord reads as off.
            writer.message(field: useThreadSidebar, ActivityPrivacyProto.boolValue(opens))
            encoded = writer.data
        case .skipsIgnoredProfileWarning(let skips):
            top = Top.safetySettings
            field = ignoreProfileSpeedbumpDisabled
            var writer = ProtobufWriter()
            writer.varint(field: ignoreProfileSpeedbumpDisabled, 1)
            encoded = skips ? writer.data : nil
        }
        var current = Data()
        var reader = ProtobufReader(blob)
        while let entry = reader.next() {
            if entry.number == top, let data = reader.data(for: entry) { current = data }
        }
        var outer = ProtobufWriter()
        outer.message(field: top, ActivityPrivacyProto.replacing(field: field, with: encoded, in: current))
        return outer.base64
    }
}
