import Foundation

/// MurmurHash3, the x86 32-bit variant, over a string's UTF-8 bytes.
///
/// Discord names a member list whose audience is restricted with this — the
/// `murmurhash` package's `v3` at seed 0, which encodes the string as UTF-8
/// first. See `MemberList.id(for:everyonePermissions:)`.
public enum MurmurHash3 {
    public static func hash32(_ string: String, seed: UInt32 = 0) -> UInt32 {
        let bytes = Array(string.utf8)
        let c1: UInt32 = 0xcc9e_2d51
        let c2: UInt32 = 0x1b87_3593
        var hash = seed

        func scramble(_ value: UInt32) -> UInt32 {
            var k = value &* c1
            k = k << 15 | k >> 17
            return k &* c2
        }

        let whole = bytes.count & ~3
        var index = 0
        while index < whole {
            let block = UInt32(bytes[index])
                | UInt32(bytes[index + 1]) << 8
                | UInt32(bytes[index + 2]) << 16
                | UInt32(bytes[index + 3]) << 24
            hash ^= scramble(block)
            hash = hash << 13 | hash >> 19
            hash = hash &* 5 &+ 0xe654_6b64
            index += 4
        }

        var tail: UInt32 = 0
        switch bytes.count & 3 {
        case 3:
            tail ^= UInt32(bytes[whole + 2]) << 16
            fallthrough
        case 2:
            tail ^= UInt32(bytes[whole + 1]) << 8
            fallthrough
        case 1:
            tail ^= UInt32(bytes[whole])
            hash ^= scramble(tail)
        default:
            break
        }

        hash ^= UInt32(truncatingIfNeeded: bytes.count)
        hash ^= hash >> 16
        hash = hash &* 0x85eb_ca6b
        hash ^= hash >> 13
        hash = hash &* 0xc2b2_ae35
        hash ^= hash >> 16
        return hash
    }
}
