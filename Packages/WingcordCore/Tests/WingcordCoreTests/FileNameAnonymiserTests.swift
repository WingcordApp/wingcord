import Foundation
import Testing
@testable import WingcordCore

/// Vencord's AnonymiseFileNames, against its own code: the endings below are
/// what the plugin's `anonymise` gives, run in Node.
@Suite("File name anonymiser")
struct FileNameAnonymiserTests {

    @Test("The ending is the plugin's, quirks included", arguments: [
        ("photo.png", ".png"), ("archive.tar.gz", ".tar.gz"), ("backup.tar.zst", ".tar.zst"),
        ("notes", ""), (".bashrc", ".bashrc"), ("a.tar", ".tar"), ("x.tar.gz.part", ".part"),
        ("x.tar.g-z", ".g-z"), ("x.tar.", "."), ("a.b.c.jpeg", ".jpeg"), ("SPOILER_cat.gif", ".gif"),
        ("trailing.", "."), ("café.tar.bz2", ".tar.bz2"), ("tar.gz", ".gz"), ("x.TAR.gz", ".gz"),
        ("dir.tar.gz.tar.xz", ".tar.xz"), ("x.tar.ü", ".ü"),
    ])
    func ending(name: String, expected: String) {
        #expect(FileNameAnonymiser.ending(of: name) == expected)
    }

    @Test("Random Characters: so many of the plugin's alphabet, then the ending")
    func random() {
        var generator = SystemRandomNumberGenerator()
        let name = FileNameAnonymiser.anonymise(
            "holiday photo.tar.gz", method: .randomCharacters, length: 7, consistentName: "image",
            now: .now, using: &generator
        )
        #expect(name.hasSuffix(".tar.gz"))
        let stem = name.dropLast(".tar.gz".count)
        #expect(stem.count == 7)
        #expect(stem.allSatisfy { "0123456789bdfhjkmnpqrstvwxz".contains($0) })
        let none = FileNameAnonymiser.anonymise(
            "a.png", method: .randomCharacters, length: -3, consistentName: "", now: .now, using: &generator
        )
        #expect(none == ".png")
    }

    @Test("Consistent and Timestamp")
    func consistentAndTimestamp() {
        var generator = SystemRandomNumberGenerator()
        #expect(FileNameAnonymiser.anonymise(
            "IMG_2041.HEIC", method: .consistent, length: 7, consistentName: "image", now: .now, using: &generator
        ) == "image.HEIC")
        let moment = Date(timeIntervalSince1970: 1_759_840_123.4567)
        #expect(FileNameAnonymiser.anonymise(
            "clip.mov", method: .timestamp, length: 7, consistentName: "image", now: moment, using: &generator
        ) == "1759840123456.mov")
    }

    @Test("The settings' labels are the plugin's, in its order")
    func labels() {
        #expect(FileNameAnonymiser.Method.allCases.map(\.title) == ["Random Characters", "Consistent", "Timestamp"])
    }
}
