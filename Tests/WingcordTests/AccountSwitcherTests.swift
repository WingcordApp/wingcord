import Foundation
import Testing
@testable import Wingcord
@testable import WingcordCore

@Suite("The accounts on this Mac")
struct AccountListTests {
    private func account(_ id: Int, expired: Bool = false) -> StoredAccount {
        StoredAccount(id: String(id), username: "user\(id)", isSessionExpired: expired)
    }

    private func ids(_ list: AccountList) -> [String] { list.accounts.map(\.id) }

    @Test func signingInPutsItFirst() {
        var list = AccountList([account(1), account(2)])
        let dropped = list.signedIn(account(3))
        #expect(ids(list) == ["3", "1", "2"])
        #expect(dropped.isEmpty)
    }

    @Test func signingInAgainDoesNotListItTwice() {
        var list = AccountList([account(1), account(2)])
        _ = list.signedIn(account(2))
        #expect(ids(list) == ["2", "1"])
    }

    @Test func signingInClearsAnExpiredSession() {
        var list = AccountList([account(1, expired: true)])
        _ = list.signedIn(account(1, expired: true))
        #expect(list.accounts.first?.isSessionExpired == false)
    }

    /// Discord's own limit: a sixth logs the oldest out, and its token has to go too.
    @Test func aSixthPushesTheOldestOut() {
        var list = AccountList((1...5).map { account($0) })
        #expect(!list.canAdd)
        let dropped = list.signedIn(account(6))
        #expect(list.accounts.count == AccountList.limit)
        #expect(ids(list).first == "6")
        #expect(dropped.map(\.id) == ["5"])
    }

    /// Somebody who adds an account and says no to switching hasn't asked to wake up as it.
    @Test func addingLeavesTheLastUsedFirst() {
        var list = AccountList([account(1), account(2)])
        _ = list.added(account(3))
        #expect(ids(list) == ["1", "2", "3"])
        #expect(list.accountToResume?.id == "1")
    }

    @Test func addingOneThatsThereLeavesItWhereItIsAndClearsItsExpiry() {
        var list = AccountList([account(1), account(2, expired: true), account(3)])
        let dropped = list.added(account(2))
        #expect(ids(list) == ["1", "2", "3"])
        #expect(list.accounts[1].isSessionExpired == false)
        #expect(dropped.isEmpty)
    }

    @Test func addingToAFullListPushesOutTheOldest() {
        var list = AccountList((1...5).map { account($0) })
        let dropped = list.added(account(6))
        #expect(dropped.map(\.id) == ["5"])
        #expect(ids(list) == ["1", "2", "3", "4", "6"])
    }

    @Test func aSwitchMakesItTheOneTheNextLaunchOpens() {
        var list = AccountList([account(1), account(2), account(3)])
        list.used("3")
        #expect(list.accountToResume?.id == "3")
        #expect(ids(list) == ["3", "1", "2"])
    }

    @Test func aRefreshKeepsItsPlace() {
        var list = AccountList([account(1), account(2)])
        var renamed = account(2)
        renamed.displayName = "New Name"
        list.refresh(renamed)
        #expect(ids(list) == ["1", "2"])
        #expect(list.accounts[1].preferredName == "New Name")
    }

    @Test func aRefreshOfNobodyAddsNobody() {
        var list = AccountList([account(1)])
        list.refresh(account(9))
        #expect(ids(list) == ["1"])
    }

    /// A dead last account goes to the picker, not quietly to the next one down.
    @Test func aDeadLastAccountOpensNothing() {
        var list = AccountList([account(1), account(2)])
        list.expire("1")
        #expect(list.accountToResume == nil)
        #expect(list.accounts.first?.isSessionExpired == true)
    }

    @Test func nothingStoredOpensNothing() {
        #expect(AccountList().accountToResume == nil)
        #expect(AccountList().canAdd)
    }

    @Test func removingTakesItOut() {
        var list = AccountList([account(1), account(2)])
        list.remove("1")
        #expect(ids(list) == ["2"])
    }

    /// What's already in somebody's defaults has no such key.
    @Test func anEntryFromBeforeExpiryStillReads() throws {
        let old = #"[{"id":"123","username":"alex","displayName":"Alex","avatarHash":"abc"}]"#
        let decoded = try JSONDecoder().decode([StoredAccount].self, from: Data(old.utf8))
        #expect(decoded.first?.isSessionExpired == false)
        #expect(decoded.first?.preferredName == "Alex")
    }

    @Test func itWritesAndReadsBack() throws {
        let original = [account(1, expired: true)]
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode([StoredAccount].self, from: data) == original)
    }

    @Test func aPictureComesFromItsHashOrDiscordsDefault() {
        let own = StoredAccount(id: "123456789010468812", username: "a", avatarHash: "abc")
        #expect(own.avatarURL(side: 28)?.absoluteString.contains("/avatars/123456789010468812/abc") == true)
        let none = StoredAccount(id: "123456789010468812", username: "a")
        #expect(none.avatarURL(side: 28)?.absoluteString.contains("/embed/avatars/") == true)
        #expect(none.monogram == "A")
    }
}

@MainActor
@Suite("Where an account was")
struct AccountLastPlaceTests {
    private func settings() -> AppSettings {
        AppSettings(defaults: UserDefaults(suiteName: "wingcord.tests.\(UUID())")!)
    }

    @Test func eachAccountHasItsOwn() {
        let settings = settings()
        settings.rememberConversation(guildID: 1, channelID: 10, account: "a")
        settings.rememberConversation(guildID: 2, channelID: 20, account: "b")
        #expect(settings.lastPlace(forAccount: "a")?.channelID == 10)
        #expect(settings.lastPlace(forAccount: "b")?.channelID == 20)
        #expect(settings.lastPlace(forAccount: "a")?.guildID == 1)
    }

    /// One account mustn't open in another's channel.
    @Test func anAccountNeverOpenedHasNowhereToBe() {
        let settings = settings()
        settings.rememberConversation(guildID: 1, channelID: 10, account: "a")
        #expect(settings.lastPlace(forAccount: "c") == nil)
    }

    @Test func itSurvivesARelaunch() {
        let defaults = UserDefaults(suiteName: "wingcord.tests.\(UUID())")!
        AppSettings(defaults: defaults).rememberConversation(guildID: nil, channelID: 10, account: "a")
        let reopened = AppSettings(defaults: defaults).lastPlace(forAccount: "a")
        #expect(reopened?.channelID == 10)
        #expect(reopened?.guildID == nil)
    }

    /// The single pair from before: for the first account after the update, and nobody after.
    @Test func theOldPairIsForTheFirstAccountOnly() {
        let defaults = UserDefaults(suiteName: "wingcord.tests.\(UUID())")!
        defaults.set(NSNumber(value: UInt64(5)), forKey: "startup.lastGuildID")
        defaults.set(NSNumber(value: UInt64(50)), forKey: "startup.lastChannelID")
        let settings = AppSettings(defaults: defaults)
        #expect(settings.lastPlace(forAccount: "a")?.channelID == 50)
        #expect(settings.lastPlace(forAccount: "a")?.guildID == 5)
        settings.rememberConversation(guildID: 1, channelID: 10, account: "a")
        #expect(settings.lastPlace(forAccount: "b") == nil)
    }

    @Test func nobodySignedInRemembersNothing() {
        let settings = settings()
        settings.rememberConversation(guildID: 1, channelID: 10, account: nil)
        #expect(settings.lastPlace(forAccount: "a") == nil)
    }
}

@MainActor
@Suite("What a switch would end")
struct AccountSwitchPromptTests {
    private let target = StoredAccount(id: "1", username: "work", displayName: "Work")

    @Test func itSaysWhatItCosts() {
        #expect(AccountSwitchPrompt(target: target, losses: [.call]).message
            == "If you switch to Work, you'll leave your call.")
        #expect(AccountSwitchPrompt(target: target, losses: [.call, .voiceNote]).message
            == "If you switch to Work, you'll leave your call and your voice message will be discarded.")
        #expect(AccountSwitchPrompt(target: target, losses: [.call, .voiceNote, .upload]).message
            == "If you switch to Work, you'll leave your call, your voice message will be discarded and the file you're sending will be cancelled.")
    }

    private func model() -> AppModel {
        let model = AppModel()
        DemoFixtures.populate(model)
        return model
    }

    /// The demo's in a call, so a switch there asks.
    @Test func aCallIsAskedAbout() {
        let model = model()
        #expect(model.connectedVoiceChannelID != nil)
        #expect(model.accountSwitchLosses == [.call])
        model.requestAccountSwitch(to: target)
        #expect(model.accountSwitchPrompt?.target == target)
        #expect(model.accountSwitchPrompt?.losses == [.call])
    }

    @Test func nothingToLoseIsNoQuestion() {
        let model = AppModel()
        #expect(model.accountSwitchLosses.isEmpty)
    }

    @Test func aSwitchToYourselfIsNothing() throws {
        let model = model()
        let me = try #require(model.currentUserID)
        model.requestAccountSwitch(to: StoredAccount(id: me.description, username: "me"))
        #expect(model.accountSwitchPrompt == nil)
    }

    @Test func oneThatsExpiredGoesToSignInInstead() {
        let model = model()
        var dead = target
        dead.isSessionExpired = true
        model.requestAccountSwitch(to: dead)
        #expect(model.isAddingAccount)
        #expect(model.accountSwitchPrompt == nil)
    }

    /// A slip costs a password and a code, so Log Out asks.
    @Test func loggingOutOfAnAccountAsksFirst() {
        let model = model()
        model.requestLogOut(of: target)
        #expect(model.logOutPrompt == target)
    }

    @Test func aHeldNoteIsAskedAbout() async throws {
        let model = AppModel()
        model.voiceRecorder.makeCapture = { SyntheticVoiceNoteCapture() }
        model.voiceRecorder.requestAccess = { true }
        model.voiceRecorder.start(in: ChannelID(rawValue: 1))
        let deadline = ContinuousClock.now + .seconds(30)
        while !model.voiceRecorder.flow.isRecording, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.accountSwitchLosses.contains(.voiceNote))
        model.voiceRecorder.discard()
    }
}
