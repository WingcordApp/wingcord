import Foundation
import Testing
import WingcordCore

@testable import Wingcord

// MARK: - The one control that answers three questions
//
// Starting a call, joining one that is already running, and hanging up are three
// different acts on one button, and the middle one was missing. With only two
// states, a reader who left a call was offered a button that said "Start a
// Call" — which rings the person still sitting in it — and there was no way to
// simply rejoin. Discord says "Join the call" here.
//
// **These assert the state, not the drawing.** The bug was a branch that did not
// exist, so what is pinned is that each of the three situations resolves to a
// different answer.
@MainActor
struct DirectCallControlTests {
    private let readerID = UserID(rawValue: 11)
    private let friendID = UserID(rawValue: 22)
    private let dmID = ChannelID(rawValue: 900)

    private func model() -> AppModel {
        let model = AppModel()
        model.currentUserID = readerID
        var index = ChannelIndex()
        index.replacePrivateChannels([
            Channel(id: dmID, kind: .directMessage, guildID: nil, name: "rowan", position: 0),
        ])
        model.channelIndex = index
        model.selectedChannelID = dmID
        return model
    }

    /// Nobody is in it: the control offers to start one.
    @Test("An empty conversation offers to start a call")
    func emptyConversationStarts() {
        let chrome = model().channelChrome
        #expect(chrome.canStartCall)
        #expect(!chrome.isInCall)
        #expect(!chrome.isCallOngoing)
    }

    /// **Somebody else is in it and the reader is not.** This is the state that
    /// did not exist, and the one that made a call unrejoinable.
    @Test("A call somebody else is in offers to join it, not to start one")
    func ongoingCallOffersJoin() {
        let model = model()
        model.voiceStates[friendID] = VoiceState(userID: friendID, channelID: dmID)
        let chrome = model.channelChrome
        #expect(chrome.canStartCall)
        #expect(!chrome.isInCall)
        #expect(chrome.isCallOngoing, "a call with somebody in it must be joinable")
    }

    /// Already in it: hang up, and nothing else.
    @Test("A call the reader is in offers only to leave it")
    func joinedCallOffersLeave() {
        let model = model()
        model.voiceStates[friendID] = VoiceState(userID: friendID, channelID: dmID)
        model.voiceStates[readerID] = VoiceState(userID: readerID, channelID: dmID)
        model.connectedVoiceChannelID = dmID
        let chrome = model.channelChrome
        #expect(chrome.isInCall)
        #expect(!chrome.isCallOngoing, "the reader's own presence is not somebody else's")
    }

    /// **Our own voice state is not somebody else's.** Reading the states
    /// without excluding the reader would make every call the reader had ever
    /// been in look permanently joinable.
    @Test("The reader alone in a channel they have left is not an ongoing call")
    func ownStaleStateIsNotACall() {
        let model = model()
        model.voiceStates[readerID] = VoiceState(userID: readerID, channelID: dmID)
        #expect(!model.channelChrome.isCallOngoing)
    }
}
