import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// The list on screen is filled back in where it lost people (Alex,
/// 2026-11-18: "after some time, some users just fail to load").
@MainActor
@Suite("Member list repair")
struct MemberListRepairTests {

    @Test("Holes are the rows a page counts and holds nothing for, headings aside")
    func holesCountOnlyCountedRows() {
        var list = MemberList()
        let groups = [MemberList.Group(id: .online, count: 5)]
        list.apply(
            [.sync(start: 0, rows: [
                .group(.online), .member(UserID(rawValue: 1)), nil,
                .member(UserID(rawValue: 3)), nil, .member(UserID(rawValue: 5)),
            ])],
            groups: groups
        )
        #expect(SessionController.holes(in: list, pages: [0...99]) == 2)
        // A page past the list's end counts nothing.
        #expect(SessionController.holes(in: list, pages: [100...199]) == 0)
    }
}

/// An app's emoji, opened from its card (Alex, 2026-11-18).
@MainActor
@Suite("App emoji card")
struct AppEmojiCardTests {

    @Test("An app's own emoji says which app, in Discord's words, with no server under it")
    func saysWhichApp() {
        let model = AppModel()
        let emoji = EmojiRef(id: EmojiID(rawValue: 1_300_000_000_000_000_001), name: "gh_success")
        model.expressionSources[1_300_000_000_000_000_001] = .application(name: "SakuraCord", iconHash: nil)
        let info = model.expressionInfo(for: ExpressionInfoRequest(subject: .emoji(emoji), anchor: .zero))
        #expect(info.detail == "This emoji is from the SakuraCord app")
        #expect(info.source == nil)
    }
}
