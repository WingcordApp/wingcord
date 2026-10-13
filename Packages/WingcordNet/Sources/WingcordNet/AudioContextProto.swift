import Foundation
import WingcordCore

/// The settings proto's `audio_context_settings` (field 16): each person's
/// volume and mute, for their voice and for their stream — see
/// `AudioContextSettings` for the descriptor and Discord's writer's rules.
///
/// **Read whole, written one entry at a time.** Discord's updater replaces a
/// top-level field whole, so the write carries the entire message; but every
/// entry this write did not change goes back as the bytes that came, and an
/// entry that did change keeps any field this client cannot name — a reader
/// that rebuilds what it only partly understands deletes the rest.
public enum AudioContextProto {
    static let field = 16

    private enum MapField {
        static let user = 1
        static let stream = 2
        static let key = 1
        static let value = 2
    }

    private enum EntryField {
        static let muted = 1
        static let volume = 2
        static let modifiedAt = 3
        static let soundboardMuted = 4
    }

    /// The settings in a blob, or nil when it carries none — an update about
    /// something else.
    static func decode(_ data: Data) -> AudioContextSettings? {
        var reader = ProtobufReader(data)
        var found: AudioContextSettings?
        while let field = reader.next() {
            guard field.number == Self.field, field.wireType == 2 else { continue }
            found = decodeSettings(reader.reader(for: field))
        }
        return found
    }

    private static func decodeSettings(_ source: ProtobufReader) -> AudioContextSettings {
        var settings = AudioContextSettings()
        var reader = source
        while let field = reader.next() {
            guard field.wireType == 2,
                  let context = context(of: field.number),
                  let (key, value) = entry(in: reader.reader(for: field))
            else { continue }
            settings[context][UserID(rawValue: key)] = decodeEntry(value)
        }
        return settings
    }

    private static func context(of mapField: Int) -> AudioContextSettings.Context? {
        switch mapField {
        case MapField.user: .user
        case MapField.stream: .stream
        default: nil
        }
    }

    /// A map entry's key and the reader over its value.
    private static func entry(in source: ProtobufReader) -> (UInt64, ProtobufReader)? {
        var pair = source
        var key: UInt64?
        var value = ProtobufReader(Data())
        while let part = pair.next() {
            if part.number == MapField.key, part.wireType == 1 {
                key = part.value
            } else if part.number == MapField.value, part.wireType == 2 {
                value = pair.reader(for: part)
            }
        }
        guard let key, key != 0 else { return nil }
        return (key, value)
    }

    /// One person's setting. **Proto3: an absent field is zero**, and a volume
    /// of zero is a person turned all the way down.
    private static func decodeEntry(_ source: ProtobufReader) -> AudioContextSettings.Entry {
        var entry = AudioContextSettings.Entry(volume: 0)
        var reader = source
        while let field = reader.next() {
            switch (field.number, field.wireType) {
            case (EntryField.muted, 0): entry.isMuted = field.value != 0
            case (EntryField.volume, 5):
                entry.volume = Double(Float(bitPattern: UInt32(truncatingIfNeeded: field.value))) / 100
            case (EntryField.modifiedAt, 1): entry.modifiedAt = field.value
            case (EntryField.soundboardMuted, 0): entry.isSoundboardMuted = field.value != 0
            default: break
            }
        }
        return entry
    }

    // MARK: Writing

    /// One person's setting as it now stands, or nil to remove it.
    public struct Change: Sendable, Equatable {
        public var context: AudioContextSettings.Context
        public var userID: UserID
        public var entry: AudioContextSettings.Entry?

        public init(context: AudioContextSettings.Context, userID: UserID, entry: AudioContextSettings.Entry?) {
            self.context = context
            self.userID = userID
            self.entry = entry
        }
    }

    /// The body of `PATCH /users/@me/settings-proto/1` for these changes.
    ///
    /// - Parameter blob: the whole settings blob, fetched just before.
    static func patch(_ changes: [Change], in blob: Data) -> String {
        var message = Data()
        var reader = ProtobufReader(blob)
        while let field = reader.next() {
            guard field.number == Self.field, let data = reader.data(for: field) else { continue }
            message = data
        }
        for change in changes {
            message = applying(change, to: message)
        }
        message = pruned(message)
        var outer = ProtobufWriter()
        outer.message(field: Self.field, message)
        return outer.base64
    }

    /// The message with one person's entry rewritten, added or removed.
    private static func applying(_ change: Change, to message: Data) -> Data {
        let mapField = change.context == .user ? MapField.user : MapField.stream
        let key = change.userID.rawValue
        var out = Data()
        var previous: Data?
        var reader = ProtobufReader(message)
        while let field = reader.next() {
            guard let raw = reader.rawField(field) else { continue }
            guard field.number == mapField, field.wireType == 2,
                  let (entryKey, value) = entry(in: reader.reader(for: field)),
                  entryKey == key
            else {
                out.append(raw)
                continue
            }
            // A duplicate of the key — which a merge would let win — goes too.
            if previous == nil { previous = valueBytes(of: value) }
        }
        guard let entry = change.entry else { return out }
        var pair = ProtobufWriter()
        pair.fixed64(field: MapField.key, key)
        pair.message(field: MapField.value, encode(entry, over: previous ?? Data()))
        var framed = ProtobufWriter()
        framed.message(field: mapField, pair.data)
        out.append(framed.data)
        return out
    }

    /// The value's own bytes, from a reader positioned over them.
    private static func valueBytes(of reader: ProtobufReader) -> Data {
        var out = Data()
        var walker = reader
        while let field = walker.next() {
            if let raw = walker.rawField(field) { out.append(raw) }
        }
        return out
    }

    /// The four fields this client names, written over an entry's old bytes so
    /// anything else in it survives.
    private static func encode(_ entry: AudioContextSettings.Entry, over old: Data) -> Data {
        func field(_ build: (inout ProtobufWriter) -> Void) -> Data? {
            var writer = ProtobufWriter()
            build(&writer)
            return writer.data.isEmpty ? nil : writer.data
        }
        var value = old
        value = ActivityPrivacyProto.replacing(
            field: EntryField.muted,
            with: field { if entry.isMuted { $0.varint(field: EntryField.muted, 1) } },
            in: value
        )
        value = ActivityPrivacyProto.replacing(
            field: EntryField.volume,
            with: field {
                let volume = Float(entry.volume * 100)
                if volume != 0 { $0.float(field: EntryField.volume, volume) }
            },
            in: value
        )
        value = ActivityPrivacyProto.replacing(
            field: EntryField.modifiedAt,
            with: field { if entry.modifiedAt != 0 { $0.fixed64(field: EntryField.modifiedAt, entry.modifiedAt) } },
            in: value
        )
        value = ActivityPrivacyProto.replacing(
            field: EntryField.soundboardMuted,
            with: field { if entry.isSoundboardMuted { $0.varint(field: EntryField.soundboardMuted, 1) } },
            in: value
        )
        return value
    }

    /// Each map at Discord's 300, the oldest gone first.
    private static func pruned(_ message: Data) -> Data {
        var stamps: [Int: [(key: UInt64, modifiedAt: UInt64)]] = [:]
        var reader = ProtobufReader(message)
        while let field = reader.next() {
            guard field.wireType == 2, context(of: field.number) != nil,
                  let (key, value) = entry(in: reader.reader(for: field))
            else { continue }
            stamps[field.number, default: []].append((key, decodeEntry(value).modifiedAt))
        }
        var dropped: [Int: Set<UInt64>] = [:]
        for (map, entries) in stamps where entries.count > AudioContextSettings.capacity {
            let oldest = entries.sorted { $0.modifiedAt < $1.modifiedAt }
                .prefix(entries.count - AudioContextSettings.capacity)
            dropped[map] = Set(oldest.map(\.key))
        }
        guard !dropped.isEmpty else { return message }
        var out = Data()
        reader = ProtobufReader(message)
        while let field = reader.next() {
            guard let raw = reader.rawField(field) else { continue }
            if let keys = dropped[field.number], field.wireType == 2,
               let (key, _) = entry(in: reader.reader(for: field)), keys.contains(key) {
                continue
            }
            out.append(raw)
        }
        return out
    }
}
