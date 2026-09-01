import Foundation
import Testing

@testable import WingcordVoice

// MARK: - Reading the working group's vectors
//
// The MLS interop vectors are JSON with every byte string as lowercase hex and
// every absent value as `null`. This is the whole of the plumbing for them, so
// the suites themselves read as protocol statements rather than as parsing.

enum Vectors {
    /// One vector file, already narrowed to ciphersuite 2 where it has one.
    static func load(_ name: String) throws -> [[String: Any]] {
        guard let url = Bundle.module.url(
            forResource: name, withExtension: "json", subdirectory: "Vectors"
        ) else {
            Issue.record("missing test vector file \(name).json")
            return []
        }
        let data = try Data(contentsOf: url)
        return try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
    }
}

extension Dictionary where Key == String, Value == Any {
    func hex(_ key: String) -> [UInt8] {
        guard let string = self[key] as? String else { return [] }
        return [UInt8](hexString: string)
    }

    func optionalHex(_ key: String) -> [UInt8]? {
        guard let string = self[key] as? String else { return nil }
        return [UInt8](hexString: string)
    }

    func int(_ key: String) -> Int { (self[key] as? NSNumber)?.intValue ?? 0 }
    func uint32(_ key: String) -> UInt32 { (self[key] as? NSNumber)?.uint32Value ?? 0 }
    func uint64(_ key: String) -> UInt64 { (self[key] as? NSNumber)?.uint64Value ?? 0 }
    func string(_ key: String) -> String { self[key] as? String ?? "" }
    func dict(_ key: String) -> [String: Any] { self[key] as? [String: Any] ?? [:] }
    func array(_ key: String) -> [Any] { self[key] as? [Any] ?? [] }
}

extension [UInt8] {
    init(hexString: String) {
        var bytes = [UInt8]()
        bytes.reserveCapacity(hexString.count / 2)
        var high: UInt8?
        for character in hexString.utf8 {
            let nibble: UInt8
            switch character {
            case 0x30...0x39: nibble = character - 0x30
            case 0x61...0x66: nibble = character - 0x61 + 10
            case 0x41...0x46: nibble = character - 0x41 + 10
            default: continue
            }
            if let value = high {
                bytes.append(value << 4 | nibble)
                high = nil
            } else {
                high = nibble
            }
        }
        self = bytes
    }

    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
