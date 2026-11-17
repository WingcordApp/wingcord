import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

@testable import Wingcord

/// CALL_DELETE ends a conversation's call for everyone — and the people last
/// seen in it go with it (Alex, 2026-11-17: a call that had ended still showed
/// its lobby, with the friend sitting in it, five minutes later).
@MainActor
struct CallEndedTests {
    private let readerID = UserID(rawValue: 11)
    private let friendID = UserID(rawValue: 22)
    private let dmID = ChannelID(rawValue: 900)
    private let otherDMID = ChannelID(rawValue: 901)

    private func setUp() -> (AppModel, VoiceController) {
        let model = AppModel()
        model.currentUserID = readerID
        let voice = VoiceController(model: model, rest: DiscordREST(protocolClasses: [OfflineProtocol.self]))
        return (model, voice)
    }

    @Test("An ended call takes the people still listed in it")
    func endedCallClearsItsPeople() {
        let (model, voice) = setUp()
        model.voiceStates[friendID] = VoiceState(userID: friendID, channelID: dmID)
        voice.applyCallEnded(dmID)
        #expect(model.voiceStates[friendID] == nil)
    }

    @Test("A call gone unavailable is an outage, not an ending: its people stay")
    func unavailableKeepsItsPeople() {
        let (model, voice) = setUp()
        model.voiceStates[friendID] = VoiceState(userID: friendID, channelID: dmID)
        voice.applyCallEnded(dmID, isUnavailable: true)
        #expect(model.voiceStates[friendID] != nil)
    }

    @Test("Somebody in another conversation's call is left alone")
    func otherCallUntouched() {
        let (model, voice) = setUp()
        model.voiceStates[friendID] = VoiceState(userID: friendID, channelID: otherDMID)
        voice.applyCallEnded(dmID)
        #expect(model.voiceStates[friendID]?.channelID == otherDMID)
    }
}
