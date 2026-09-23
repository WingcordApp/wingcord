import Foundation
import Testing
@testable import WingcordNet

/// Slowmode's two answers on the wire: the wait a typing call reports, and the
/// refusal a send gets inside one.
@Suite("Slowmode on the wire")
struct SlowmodeWireTests {

    @Test("A typing answer carries the message cooldown, in seconds")
    func typingCooldown() {
        // Verbatim from `conversations + slowmode + jump to recent.har`: the
        // POST /typing two seconds after a send into a slowmode channel.
        let body = Data(#"{"message_send_cooldown_ms":1096,"thread_create_cooldown_ms":0}"#.utf8)
        #expect(DiscordREST.slowmodeCooldown(typingResponse: body) == 1.096)
    }

    @Test("A 204's empty body, and a zero, both mean nothing is running")
    func noCooldown() {
        #expect(DiscordREST.slowmodeCooldown(typingResponse: Data()) == nil)
        // Only a thread cooldown running: the message field is present and 0.
        let threadOnly = Data(#"{"message_send_cooldown_ms":0,"thread_create_cooldown_ms":4200}"#.utf8)
        #expect(DiscordREST.slowmodeCooldown(typingResponse: threadOnly) == nil)
    }

    @Test("A 20016 refusal is slowmode, carrying Discord's wait")
    func refusal() {
        let body = Data(
            #"{"message":"You are being rate limited.","retry_after":4.2,"global":false,"code":20016}"#.utf8
        )
        guard case .slowmode(let wait)? = DiscordREST.slowmodeRefusal(status: 429, data: body) else {
            Issue.record("a 20016 was not read as slowmode")
            return
        }
        #expect(wait == 4.2)
        // Every path that turns a body into a failure says the same thing.
        guard case .slowmode = DiscordREST.apiFailure(status: 429, data: body) else {
            Issue.record("apiFailure did not report slowmode")
            return
        }
    }

    @Test("A refusal that names no wait is still slowmode")
    func refusalWithoutWait() {
        let body = Data(#"{"message":"Slowmode rate limit","code":20016}"#.utf8)
        guard case .slowmode(let wait)? = DiscordREST.slowmodeRefusal(status: 429, data: body) else {
            Issue.record("a 20016 without retry_after was not read as slowmode")
            return
        }
        #expect(wait == nil)
    }

    @Test("An ordinary rate limit is not slowmode, and neither is a success")
    func notSlowmode() {
        let budget = Data(#"{"message":"You are being rate limited.","retry_after":0.5,"global":false}"#.utf8)
        #expect(DiscordREST.slowmodeRefusal(status: 429, data: budget) == nil)
        let success = Data(#"{"code":20016}"#.utf8)
        #expect(DiscordREST.slowmodeRefusal(status: 200, data: success) == nil)
    }
}
