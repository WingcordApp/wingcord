import Foundation
import Testing
@testable import WingcordCore

/// Discord's soundboard frecency (module 283047 with the soundboard store's
/// options), reproduced.
struct SoundFrecencyTests {
    /// 1 October 2026, noon UTC — well past the cut-off.
    private let now = Date(timeIntervalSince1970: 1_790_856_000)

    private func ms(daysAgo days: Double) -> UInt64 {
        UInt64((now.timeIntervalSince1970 - days * 86_400) * 1000)
    }

    @Test("A use scores by its age, and frecency is total uses × score ÷ uses")
    func scoring() {
        let table = SoundFrecency(history: [
            "1": .init(totalUses: 1, recentUses: [ms(daysAgo: 1)]),
            "2": .init(totalUses: 4, recentUses: [ms(daysAgo: 20), ms(daysAgo: 2)]),
            "3": .init(totalUses: 1, recentUses: [ms(daysAgo: 85)]),
        ], now: now)
        #expect(table.history["1"]?.score == 100)
        #expect(table.history["1"]?.frecency == 100)
        // 50 + 100 = 150; ⌈4 × 150 ÷ 2⌉ = 300.
        #expect(table.history["2"]?.score == 150)
        #expect(table.history["2"]?.frecency == 300)
        #expect(table.history["3"]?.score == 1)
        #expect(table.frequently == ["2", "1", "3"])
    }

    /// The soundboard's own cut-off: 29 June 2026.
    @Test("A use before the cut-off scores nothing, and an entry of nothing is dropped")
    func cutoff() {
        let before = UInt64(SoundFrecency.cutoff.timeIntervalSince1970 * 1000) - 86_400_000 * 2
        let table = SoundFrecency(history: ["old": .init(totalUses: 9, recentUses: [before])], now: now)
        #expect(table.history["old"] == nil)
    }

    @Test("A play counts in full and keeps only the last ten uses")
    func trackKeepsTen() {
        var table = SoundFrecency(history: [:], now: now)
        for minute in 0..<12 {
            table.track("7", at: now.addingTimeInterval(Double(minute) * 60))
        }
        #expect(table.history["7"]?.totalUses == 12)
        #expect(table.history["7"]?.recentUses.count == 10)
        #expect(table.history["7"]?.recentUses.first == UInt64(now.addingTimeInterval(120).timeIntervalSince1970 * 1000))
    }

    @Test("What is written is the hundred played most recently")
    func writtenLimit() {
        var history: [String: SoundFrecency.Use] = [:]
        for index in 0..<105 {
            history["\(index)"] = .init(totalUses: 1, recentUses: [ms(daysAgo: Double(index) / 10)])
        }
        let written = SoundFrecency(history: history, now: now).written
        #expect(written.count == 100)
        #expect(written["0"] != nil)
        #expect(written["104"] == nil)
    }
}
