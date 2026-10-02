import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// The composers' words kept across a relaunch, each test on a defaults suite
/// of its own — run against `.standard` they would share one table.
@Suite("Drafts")
@MainActor
struct DraftStoreTests {

    private let account = UserID(rawValue: 7)
    private let general = ChannelID(rawValue: 1001)
    private let lounge = ChannelID(rawValue: 1002)

    private func suite() -> UserDefaults {
        UserDefaults(suiteName: "wingcord.tests.\(UUID().uuidString)")!
    }

    @Test("A draft written and flushed is there after a relaunch")
    func survivesARelaunch() {
        let defaults = suite()
        let store = DraftStore(defaults: defaults)
        _ = store.open(for: account)
        store.note("half a thought", in: general)
        store.flush()

        let relaunched = DraftStore(defaults: defaults)
        #expect(relaunched.open(for: account)[general]?.text == "half a thought")
    }

    @Test("Signing out writes what is waiting and lets the account go")
    func closeWrites() {
        let defaults = suite()
        let store = DraftStore(defaults: defaults)
        _ = store.open(for: account)
        store.note("before the sign-out", in: general)
        store.close()
        #expect(store.drafts.isEmpty)

        // Nothing is noted for nobody.
        store.note("after it", in: lounge)
        #expect(store.drafts.isEmpty)
        #expect(DraftStore(defaults: defaults).open(for: account)[general]?.text == "before the sign-out")
    }

    @Test("Each account has its own drafts")
    func perAccount() {
        let defaults = suite()
        let store = DraftStore(defaults: defaults)
        _ = store.open(for: account)
        store.note("mine", in: general)
        #expect(store.open(for: UserID(rawValue: 8)).isEmpty)
        #expect(store.open(for: account)[general]?.text == "mine")
    }

    @Test("An emptied composer has no draft, and whitespace is not one")
    func blankIsNone() {
        let store = DraftStore(defaults: suite())
        _ = store.open(for: account)
        store.note("words", in: general)
        store.note("", in: general)
        store.note("  \n ", in: lounge)
        #expect(store.drafts.isEmpty)
    }

    @Test("A stored draft stops at Discord's ceiling")
    func capped() {
        let store = DraftStore(defaults: suite())
        _ = store.open(for: account)
        store.note(String(repeating: "a", count: DraftStore.maximumLength + 300), in: general)
        #expect(store.drafts[general]?.text.count == DraftStore.maximumLength)
    }

    @Test("The same words again are no edit, so they keep their place in the list")
    func equalTextKeepsItsStamp() {
        let store = DraftStore(defaults: suite())
        _ = store.open(for: account)
        let first = Date(timeIntervalSince1970: 1_790_000_000)
        store.note("same", in: general, at: first)
        store.note("other", in: lounge, at: first.addingTimeInterval(10))
        store.note("same", in: general, at: first.addingTimeInterval(20))
        #expect(store.drafts[general]?.editedAt == first)
        #expect(store.recentlyEdited == [lounge, general])
    }

    @Test("Past the capacity the oldest draft goes")
    func oldestGoes() {
        let store = DraftStore(defaults: suite())
        _ = store.open(for: account)
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        for index in 0...DraftStore.capacity {
            store.note("draft \(index)", in: ChannelID(rawValue: UInt64(5000 + index)), at: start.addingTimeInterval(Double(index)))
        }
        #expect(store.drafts.count == DraftStore.capacity)
        #expect(store.drafts[ChannelID(rawValue: 5000)] == nil)
    }

    @Test("A channel that is gone takes its draft with it")
    func forgotten() {
        let store = DraftStore(defaults: suite())
        _ = store.open(for: account)
        store.note("words", in: general)
        store.forget(general)
        #expect(store.drafts.isEmpty)
    }

    // MARK: Through the model

    @Test("Typing into a composer is what reaches the store")
    func typingIsNoted() {
        let store = DraftStore(defaults: suite())
        _ = store.open(for: account)
        let model = AppModel(drafts: store)
        model.mutateBox(general) { $0.draft = "typed" }
        #expect(store.drafts[general]?.text == "typed")
        model.mutateBox(general) { $0.draft = "" }
        #expect(store.drafts.isEmpty)
    }

    @Test("A kept draft goes back into its composer, never over words typed since")
    func restored() {
        let defaults = suite()
        let earlier = DraftStore(defaults: defaults)
        _ = earlier.open(for: account)
        earlier.note("kept", in: general)
        earlier.note("kept too", in: lounge)
        earlier.close()

        let model = AppModel(drafts: DraftStore(defaults: defaults))
        model.mutateBox(lounge) { $0.draft = "typed since" }
        model.restoreDrafts(for: account)
        #expect(model.messages(in: general)?.draft == "kept")
        #expect(model.messages(in: lounge)?.draft == "typed since")
        #expect(model.drafts.drafts[lounge]?.text == "typed since")
    }
}
