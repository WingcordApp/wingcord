import Testing
@testable import Wingcord

/// The call card's running time, drawn by its own view rather than a timer
/// text in the sidebar's graph.
@Suite("Call timer")
@MainActor
struct CallTimerTests {
    @Test("Minutes and seconds, then hours as well, in the reader's digits")
    func digits() {
        let short = CallTimerView.digits(7 * 60 + 39)
        #expect(short.filter(\.isNumber) == "739")
        let long = CallTimerView.digits(3 * 3600 + 7 * 60 + 39)
        #expect(long.filter(\.isNumber) == "30739")
        #expect(CallTimerView.digits(0).filter(\.isNumber) == "000")
    }
}
