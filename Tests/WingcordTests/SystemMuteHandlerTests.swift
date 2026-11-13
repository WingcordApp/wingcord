import Foundation
import Testing
@testable import Wingcord

/// The AirPods mute gesture's block is called by the system on a queue of its
/// own. Built as a main-actor closure it trapped there — every voice join
/// crashed (2026-11-12). Calling it off the main thread is the test: a trap
/// would take the test process down.
@Suite("The system's mute gesture")
struct SystemMuteHandlerTests {
    @Test("The block can be called from any queue, says yes at once, and hands the press to the main actor")
    func callableOffTheMainActor() async {
        let received = AsyncStream<Bool>.makeStream()
        let handler = VoiceController.systemMuteHandler { muted in
            #expect(Thread.isMainThread)
            received.continuation.yield(muted)
        }
        let answer = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: handler(true))
            }
        }
        #expect(answer)
        var iterator = received.stream.makeAsyncIterator()
        #expect(await iterator.next() == true)
    }
}
