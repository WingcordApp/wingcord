import Foundation
import Synchronization
import Testing
@testable import WingcordCore

/// The always-on log (docs/BUG-REPORTING.md D18 and §2): what it keeps, and
/// what it never keeps.
@Suite("Log rings")
struct LogRingTests {

    private func temporaryFolder() throws -> URL {
        let folder = URL.temporaryDirectory.appending(path: "wingcord-log-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test("A ring hands back what was written, oldest first")
    func readsBack() {
        let ring = LogRing(inMemoryCapacity: 1_024)
        ring.append("one\n")
        ring.append("two\n")
        #expect(String(decoding: ring.contents(), as: UTF8.self) == "one\ntwo\n")
    }

    /// **The overwritten line's tail is not a line.** Once the circle comes
    /// round, the bytes at the write position belong to a line whose head is
    /// gone; a read that kept them would start the report with half a sentence
    /// that looks like a whole one.
    @Test("A ring that has come round starts at the first whole line")
    func wrapsToWholeLines() {
        let ring = LogRing(inMemoryCapacity: 32)
        for index in 0..<10 { ring.append("line \(index) xxxx\n") }
        let text = String(decoding: ring.contents(), as: UTF8.self)
        #expect(ring.bytesWritten > 32)
        #expect(text.hasSuffix("line 9 xxxx\n"))
        for line in text.split(separator: "\n") {
            #expect(line.hasPrefix("line "), "a torn line survived: \(line)")
        }
    }

    /// A record longer than the whole ring has lost its head, so it is a torn
    /// line and is not read back — but it must not tear the next one either.
    @Test("A record longer than the ring leaves the next line whole")
    func oversizedRecord() {
        let ring = LogRing(inMemoryCapacity: 8)
        ring.append("0123456789AB\n")
        ring.append("ok\n")
        #expect(String(decoding: ring.contents(), as: UTF8.self) == "ok\n")
    }

    /// The point of the mapping: a run that dies leaves its lines in the file,
    /// and the next launch reads them.
    @Test("What one opening wrote, the next one reads")
    func survivesReopening() throws {
        let url = try temporaryFolder().appending(path: "general.wclog")
        do {
            let ring = try LogRing(url: url, capacity: 4_096)
            ring.append("before the crash\n")
        }
        let reopened = try LogRing(url: url, capacity: 4_096)
        #expect(String(decoding: reopened.contents(), as: UTF8.self) == "before the crash\n")
    }

    @Test("A second opening of a held file is refused, not shared")
    func secondOpenerIsBusy() throws {
        let url = try temporaryFolder().appending(path: "general.wclog")
        let first = try LogRing(url: url, capacity: 1_024)
        #expect(throws: LogRing.OpenError.busy) {
            _ = try LogRing(url: url, capacity: 1_024)
        }
        withExtendedLifetime(first) {}
    }

    @Test("A file of another size is started over, not trusted")
    func wrongSizeIsReformatted() throws {
        let url = try temporaryFolder().appending(path: "general.wclog")
        try Data(repeating: 0xFF, count: 300).write(to: url)
        let ring = try LogRing(url: url, capacity: 1_024)
        #expect(ring.contents().isEmpty)
        ring.append("fresh\n")
        #expect(String(decoding: ring.contents(), as: UTF8.self) == "fresh\n")
    }

    @Test("A second copy of the app takes the next folder")
    func secondStoreTakesAnotherSlot() throws {
        let folder = try temporaryFolder()
        let scrubber = LogScrubber(salt: [1, 2, 3])
        let first = LogStore.open(in: folder, scrubber: scrubber)
        let second = LogStore.open(in: folder, scrubber: scrubber)
        #expect(first.directory?.lastPathComponent == "Logs")
        #expect(second.directory?.lastPathComponent == "Logs.1")
    }
}

@Suite("Log scrubber")
struct LogScrubberTests {
    let scrubber = LogScrubber(salt: Array("test salt".utf8), home: "/Users/alexandra")

    @Test("A Discord token, an MFA token and a JWT are removed")
    func tokens() {
        // Made-up, and joined at run time: written in one piece, it reads as a real bot token to GitHub's secret scanning.
        let token = ["MTA0NjEyMzQ1Njc4OTAxMjM0NQ", "GhIjKl", "abcdefghijklmnopqrstuvwxyzABCDEFGHIJ"].joined(separator: ".")
        #expect(scrubber.scrub("sending \(token) now") == "sending <token> now")
        let mfa = "mfa." + String(repeating: "aB3_", count: 21)
        #expect(scrubber.scrub(mfa) == "<token>")
        let jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
        #expect(scrubber.scrub("auth \(jwt)") == "auth <token>")
    }

    @Test("A version number is not a token, and not an address")
    func versionsSurvive() {
        #expect(scrubber.scrub("macOS 27.3.0 build 1.2.3") == "macOS 27.3.0 build 1.2.3")
        #expect(scrubber.scrub("library 1.2.3.4.5") == "library 1.2.3.4.5")
    }

    @Test("An e-mail address is removed, whole or inside a run")
    func emails() {
        #expect(scrubber.scrub("signed in as alex.b+test@example.co.uk.") == "signed in as <email>.")
        #expect(scrubber.scrub("mailto:someone@mail.example.com") == "mailto:<email>")
        #expect(scrubber.scrub("<@123456789010468812>").hasPrefix("<@#"))
    }

    @Test("IP addresses are removed, the port kept")
    func addresses() {
        #expect(scrubber.scrub("ready: ssrc=4 192.168.1.20:50004") == "ready: ssrc=4 <ip>:50004")
        #expect(scrubber.scrub("candidate 10.0.0.1 typ host") == "candidate <ip> typ host")
        #expect(scrubber.scrub("v6 2001:db8:85a3::8a2e:370:7334 up") == "v6 <ip> up")
        #expect(scrubber.scrub("[fe80::1%en0]") == "[<ip>]")
        #expect(scrubber.scrub("mac a4:83:e7:12:34:56") == "mac <ip>")
    }

    @Test("A time of day is not an address")
    func timesSurvive() {
        #expect(scrubber.scrub("at 10:15:03 and 23:59") == "at 10:15:03 and 23:59")
    }

    @Test("A URL loses its query, credentials, IP host and attachment name")
    func urls() {
        #expect(
            scrubber.scrub("GET https://cdn.discordapp.com/attachments/1/2/passport.jpg?ex=67a8&is=67a7&hm=0f1e")
                == "GET https://cdn.discordapp.com/attachments/1/2/<file>.jpg?…"
        )
        #expect(scrubber.scrub("wss://gateway.discord.gg/?v=10&encoding=json") == "wss://gateway.discord.gg/?…")
        #expect(scrubber.scrub("https://user:pass@example.com/x") == "https://example.com/x")
        #expect(scrubber.scrub("wss://203.0.113.9:443/?v=8") == "wss://<ip>:443/?…")
        #expect(
            scrubber.scrub("HTTP 400 /guilds/1/messages/search?content=my+secret+words")
                == "HTTP 400 /guilds/1/messages/search?…"
        )
    }

    @Test("A snowflake becomes this install's hash — the same each time, and not the id")
    func snowflakes() {
        let line = scrubber.scrub("voice state -> channel=1234567890104688129 again 1234567890104688129")
        #expect(!line.contains("1234567890104688129"))
        let hash = scrubber.hash(1_234_567_890_104_688_129)
        #expect(line == "voice state -> channel=\(hash) again \(hash)")
        #expect(hash.count == 9 && hash.hasPrefix("#"))
        let other = LogScrubber(salt: Array("another install".utf8))
        #expect(other.hash(1_234_567_890_104_688_129) != hash)
    }

    @Test("A stream key's ids are hashed and its grammar kept")
    func streamKey() {
        let line = scrubber.scrub("stream watch -> guild:111111111111111111:222222222222222222:333333333333333333")
        #expect(line == "stream watch -> guild:\(scrubber.hash(111_111_111_111_111_111)):\(scrubber.hash(222_222_222_222_222_222)):\(scrubber.hash(333_333_333_333_333_333))")
    }

    @Test("Long hex goes; build ids and addresses stay")
    func hex() {
        #expect(scrubber.scrub("session 161365fbbaa7c9a3e4b2a0d556a21ae3") == "session <hex>")
        let uuid = "E621E1F8-C36C-495A-93FC-0C247A3E6E5F"
        #expect(scrubber.scrub("uuid \(uuid)") == "uuid \(uuid)")
        #expect(scrubber.scrub("pc 0x00000001045f8000") == "pc 0x00000001045f8000")
    }

    @Test("A home folder becomes ~, whoever's it is")
    func homes() {
        #expect(scrubber.scrub("/Users/alexandra/Library/Logs/x.txt") == "~/Library/Logs/x.txt")
        #expect(scrubber.scrub("open /Users/somebody/Desktop/a.mov failed") == "open ~/Desktop/a.mov failed")
    }

    @Test("The value after a sensitive key goes, however it is spelled")
    func sensitiveKeys() {
        #expect(scrubber.scrub(#"{"token":"abc","ip":"1.2.3.4","port":50004}"#) == #"{"token":"<redacted>","ip":"<redacted>","port":50004}"#)
        #expect(scrubber.scrub("identify session_id=deadbeef token=<24 chars>") == "identify session_id=<redacted> token=<<redacted> chars>")
        #expect(scrubber.scrub("a=1&password=hunter2&b=2") == "a=1&password=<redacted>&b=2")
        #expect(scrubber.scrub("Authorization: Bearer xyz") == "Authorization: <redacted> xyz")
    }

    @Test("A sensitive word in a sentence is only a word")
    func proseSurvives() {
        #expect(scrubber.scrub("session token expired, retrying") == "session token expired, retrying")
        #expect(scrubber.scrub("session started") == "session started")
    }
}

@Suite("Log messages")
struct LogMessageTests {

    @Test("A string without a label is its length, never its words")
    func stringsAreRedacted() {
        let name = "Alex’s AirPods Pro"
        let message: LogMessage = "input device \(name)"
        #expect(message.text == "input device <18 chars>")
    }

    @Test("The code's own words print when it vouches for them")
    func publicValues() {
        let codec = "opus"
        let message: LogMessage = "codec \(public: codec) bitrate \(64_000) on \(true)"
        #expect(message.text == "codec opus bitrate 64000 on true")
    }

    @Test("An id prints as a hash")
    func ids() {
        let channel = ChannelID(rawValue: 1_234_567_890_104_688_129)
        let message: LogMessage = "joined \(channel)"
        #expect(!message.text.contains("1234567890104688129"))
        #expect(message.text.hasPrefix("joined #"))
    }

    @Test("Durations and sizes read as a person reads them")
    func durationsAndSizes() {
        let message: LogMessage = "stall \(Duration.milliseconds(412)) footprint \(bytes: 245_366_784)"
        #expect(message.text == "stall 412ms footprint 234.0 MB")
    }

    @Test("An NSError is its domain, code and sentence")
    func errors() {
        let error = NSError(domain: NSURLErrorDomain, code: -1009, userInfo: [
            NSLocalizedDescriptionKey: "The Internet connection appears to be offline.",
            NSURLErrorFailingURLStringErrorKey: "https://discord.com/api/v9/users/@me?secret=1",
        ])
        let message: LogMessage = "request failed: \(error)"
        #expect(message.text == "request failed: NSURLErrorDomain -1009 The Internet connection appears to be offline.")
    }
}

@Suite("Log store")
struct LogStoreTests {
    let scrubber = LogScrubber(salt: Array("store salt".utf8), home: "/Users/alexandra")

    @Test("Faults, calls and the rest go to their own rings")
    func routing() {
        let store = LogStore.inMemory(scrubber: scrubber)
        store.write(.info, .gateway, "READY guilds=3")
        store.write(.info, .voice, "connected")
        store.write(.fault, .voice, "DAVE failed")
        #expect(store.contents(of: .general).contains("I gateway  READY guilds=3"))
        #expect(store.contents(of: .calls).contains("I voice    connected"))
        #expect(store.contents(of: .faults).contains("F voice    DAVE failed"))
        #expect(!store.contents(of: .calls).contains("DAVE failed"))
    }

    @Test("The export is every ring's lines in time order")
    func exportMerges() {
        let store = LogStore.inMemory(scrubber: scrubber)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        store.write(.info, .app, "first", at: start)
        store.write(.info, .voice, "second", at: start.addingTimeInterval(1))
        store.write(.fault, .gateway, "third", at: start.addingTimeInterval(2))
        store.write(.info, .app, "fourth", at: start.addingTimeInterval(3))
        let order = store.export().split(separator: "\n").map { $0.split(separator: " ").last.map(String.init) ?? "" }
        #expect(order == ["first", "second", "third", "fourth"])
    }

    /// **The crashes of 13 November 2026.** The mirror was a bare closure in a
    /// `Mutex`, and every line's read wrapped it two thunks deeper: an hour into
    /// a run with the session log on, one line overflowed its thread's stack.
    @Test("The mirror is called as deep on the two-thousandth line as on the first")
    func mirrorStaysShallow() {
        let store = LogStore.inMemory(scrubber: scrubber)
        let depth = Mutex(0)
        // Measured on the marked lines only: reading the stack is slow.
        store.setMirror { line in
            guard line.contains("measure") else { return }
            depth.withLock { $0 = Thread.callStackSymbols.count }
        }
        store.write(.info, .app, "measure")
        let first = depth.withLock { $0 }
        for index in 0..<2_000 { store.write(.info, .app, "line \(index)") }
        store.write(.info, .app, "measure")
        #expect(depth.withLock { $0 } == first)
    }

    @Test("A line is stamped in UTC, fixed width")
    func timestamps() {
        let date = Date(timeIntervalSince1970: 1_762_942_503.123)
        #expect(LogStore.timestamp(date) == "2025-11-12T10:15:03.123Z")
    }

    @Test("A line break inside a message stays inside its line")
    func newlinesAreEscaped() {
        let store = LogStore.inMemory(scrubber: scrubber)
        store.write(.info, .app, "two\nlines")
        #expect(store.contents(of: .general).split(separator: "\n").count == 1)
        #expect(store.contents(of: .general).contains("two\\nlines"))
    }

    /// The plan's own test: whatever a careless call site passes, the file on
    /// disk never holds a token, an e-mail, an IP, a snowflake or a home path.
    @Test("A token, an e-mail, an IP, a snowflake and a home path never reach the file")
    func nothingSensitiveReachesDisk() throws {
        let folder = URL.temporaryDirectory.appending(path: "wingcord-log-\(UUID().uuidString)")
        let store = LogStore.open(in: folder, scrubber: scrubber)
        let token = ["MTA0NjEyMzQ1Njc4OTAxMjM0NQ", "GhIjKl", "abcdefghijklmnopqrstuvwxyzABCDEFGHIJ"].joined(separator: ".")
        store.write(.fault, .rest, "failed for \(token)")
        store.write(.info, .auth, "account alex@example.com")
        store.write(.info, .voice, "ready: 203.0.113.77:50004")
        store.write(.debug, .gateway, "channel 1046123456789611532 opened")
        store.write(.info, .clips, "saved /Users/alexandra/Movies/clip.mov")

        var onDisk = ""
        for ring in LogStore.Ring.allCases {
            let url = try #require(store.directory).appending(path: "\(ring.rawValue).wclog")
            onDisk += String(decoding: try Data(contentsOf: url), as: UTF8.self)
        }
        for secret in [token, "alex@example.com", "203.0.113.77", "1046123456789611532", "/Users/alexandra"] {
            #expect(!onDisk.contains(secret), "\(secret) reached the file")
        }
        #expect(onDisk.contains("~/Movies/clip.mov"))
    }
}

/// The façade is global, so these run one at a time.
@Suite("Log levels", .serialized)
struct LogLevelTests {

    @Test("Debug lines are written only while detailed logging is on")
    func debugNeedsDetailed() {
        let store = LogStore.inMemory(scrubber: LogScrubber(salt: [9]))
        Log.install(store)
        defer {
            Log.install(nil)
            Log.setDetailed(false)
        }
        var built = 0
        func expensive() -> LogMessage {
            built += 1
            return "detail"
        }
        Log.setDetailed(false)
        Log.debug(.rest, expensive())
        #expect(built == 0, "a debug line was built while nobody asked for it")
        Log.info(.rest, "always")
        Log.setDetailed(true)
        Log.debug(.rest, expensive())
        #expect(built == 1)
        let general = store.contents(of: .general)
        #expect(general.contains("I rest     always"))
        #expect(general.contains("D rest     detail"))
    }
}
