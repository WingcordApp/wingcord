import Foundation
import Testing
@testable import Wingcord
@testable import WingcordCore

/// The Threads flyout's arithmetic.
///
/// The badge beside a row's faces is the one part of it that is not a field on
/// the wire — it is derived from two, and the derivation is captured rather than
/// guessed: `threads toolbar.har`, 2026-09-04, draws "50+" against a
/// `member_count` of 50 and "+24" against one of 29 with five faces shown.
@MainActor
@Suite("Thread browser")
struct ThreadBrowserTests {

    @Test("Fifty means at least fifty, and says so with the plus after it")
    func cappedCount() {
        // Discord stops counting at fifty, so the number is a floor rather than
        // a total — "50+" and never "+45".
        #expect(AppModel.memberBadge(count: 50, shown: 5) == "50+")
        #expect(AppModel.memberBadge(count: 80, shown: 5) == "50+")
    }

    @Test("Below the cap the badge names how many are not pictured")
    func remainderCount() {
        // 29 in the thread, five faces drawn: the capture's own row reads "+24".
        #expect(AppModel.memberBadge(count: 29, shown: 5) == "+24")
        #expect(AppModel.memberBadge(count: 26, shown: 5) == "+21")
    }

    @Test("A thread with nothing left over gets no badge at all")
    func noBadgeWhenAllShown() {
        // Everybody is already pictured, so a badge would be "+0".
        #expect(AppModel.memberBadge(count: 5, shown: 5) == nil)
        #expect(AppModel.memberBadge(count: 3, shown: 5) == nil)
        #expect(AppModel.memberBadge(count: 0, shown: 0) == nil)
        #expect(AppModel.memberBadge(count: nil, shown: 5) == nil)
    }

    @Test("A row with no faces resolved still carries its count")
    func badgeSurvivesUnknownFaces() {
        // `member_ids_preview` is five bare ids with no user objects behind
        // them, so a session that has met none of these people draws no faces —
        // the badge is then the only thing saying how many are in there.
        #expect(AppModel.memberBadge(count: 29, shown: 0) == "+29")
    }
}
