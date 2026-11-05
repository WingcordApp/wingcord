import Foundation
import Testing
@testable import WingcordCore

@Suite("Voice note flow")
struct VoiceNoteFlowTests {
    private let here = ChannelID(rawValue: 1)
    private let there = ChannelID(rawValue: 2)

    @Test func itStartsInAChannelAndStopsIntoReview() {
        var flow = VoiceNoteFlow()
        let answer = flow.start(in: here)
        #expect(answer == .started)
        #expect(flow.isRecording)
        #expect(flow.channelID == here)
        let answer2 = flow.stop(durationSeconds: 3)
        #expect(answer2 == .review)
        #expect(flow.isInReview)
        #expect(flow.channelID == here)
    }

    /// Discord drops these without a word, and so does this.
    @Test func aSlipOfTheHandIsDropped() {
        var flow = VoiceNoteFlow()
        _ = flow.start(in: here)
        let answer = flow.stop(durationSeconds: 0.49)
        #expect(answer == .dropped)
        #expect(flow.phase == .idle)
    }

    @Test func exactlyHalfASecondIsKept() {
        var flow = VoiceNoteFlow()
        _ = flow.start(in: here)
        let answer = flow.stop(durationSeconds: 0.5)
        #expect(answer == .review)
    }

    @Test func stoppingWithNothingGoingDoesNothing() {
        var flow = VoiceNoteFlow()
        let answer = flow.stop(durationSeconds: 3)
        #expect(answer == .nothing)
        #expect(flow.phase == .idle)
    }

    @Test func stoppingTwiceKeepsTheReview() {
        var flow = VoiceNoteFlow()
        _ = flow.start(in: here)
        _ = flow.stop(durationSeconds: 3)
        let answer = flow.stop(durationSeconds: 0.1)
        #expect(answer == .nothing)
        #expect(flow.isInReview)
    }

    @Test func aSecondPressIsNotASecondRecording() {
        var flow = VoiceNoteFlow()
        _ = flow.start(in: here)
        let answer = flow.start(in: here)
        #expect(answer == .alreadyHere)
        #expect(flow.isRecording)
    }

    /// One held note at a time: Discord's card, go back or discard.
    @Test func aNoteHeldElsewhereIsAsked() {
        var flow = VoiceNoteFlow()
        _ = flow.start(in: here)
        _ = flow.stop(durationSeconds: 3)
        let answer = flow.start(in: there)
        #expect(answer == .heldElsewhere(here))
        #expect(flow.channelID == here)
        #expect(flow.isInReview)
    }

    @Test func aNoteElsewhereIsNothingHere() {
        var flow = VoiceNoteFlow()
        _ = flow.start(in: here)
        #expect(flow.phase(in: here) == .recording(here))
        #expect(flow.phase(in: there) == .idle)
    }

    @Test func discardingFreesTheMicrophone() {
        var flow = VoiceNoteFlow()
        _ = flow.start(in: here)
        _ = flow.stop(durationSeconds: 3)
        flow.discard()
        #expect(flow.phase == .idle)
        let answer = flow.start(in: there)
        #expect(answer == .started)
    }

    @Test func onlyAHeldNoteCanBeSent() {
        var flow = VoiceNoteFlow()
        let answer = flow.sent()
        #expect(!answer)
        _ = flow.start(in: here)
        let answer2 = flow.sent()
        #expect(!answer2)
        #expect(flow.isRecording)
        _ = flow.stop(durationSeconds: 3)
        let answer3 = flow.sent()
        #expect(answer3)
        #expect(flow.phase == .idle)
    }

    // MARK: Limits

    @Test func theTimerWarnsAsDiscordsDoes() {
        #expect(VoiceNoteFlow.Warning(elapsedSeconds: 0) == .none)
        #expect(VoiceNoteFlow.Warning(elapsedSeconds: 1_169.4) == .none)
        #expect(VoiceNoteFlow.Warning(elapsedSeconds: 1_169.5) == .approaching)
        #expect(VoiceNoteFlow.Warning(elapsedSeconds: 1_184.4) == .approaching)
        #expect(VoiceNoteFlow.Warning(elapsedSeconds: 1_184.5) == .imminent)
    }

    @Test func itBlinksFasterAsTheLimitNears() {
        #expect(VoiceNoteFlow.Warning.none.blinkInterval(reduceMotion: false) == nil)
        #expect(VoiceNoteFlow.Warning.approaching.blinkInterval(reduceMotion: false) == 0.5)
        #expect(VoiceNoteFlow.Warning.imminent.blinkInterval(reduceMotion: false) == 0.25)
        #expect(VoiceNoteFlow.Warning.imminent.blinkInterval(reduceMotion: true) == 1)
    }

    @Test func itStopsItselfAtTheLimit() {
        #expect(!VoiceNoteFlow.hasReachedLimit(elapsedSeconds: 1_199.4))
        #expect(VoiceNoteFlow.hasReachedLimit(elapsedSeconds: 1_199.5))
    }

    // MARK: Whether it's offered

    @Test func aDirectMessageNeedsNoPermission() {
        #expect(VoiceNoteEligibility(isPrivate: true).isOffered)
    }

    @Test func aChannelNeedsThePermission() {
        #expect(!VoiceNoteEligibility().isOffered)
        #expect(VoiceNoteEligibility(canSendVoiceMessages: true).isOffered)
    }

    @Test(arguments: [
        VoiceNoteEligibility(canSendVoiceMessages: true, isForumLike: true),
        VoiceNoteEligibility(canSendVoiceMessages: true, isWritingPost: true),
        VoiceNoteEligibility(canSendVoiceMessages: true, isEditing: true),
        VoiceNoteEligibility(canSendVoiceMessages: true, hasFiles: true),
        VoiceNoteEligibility(canSendVoiceMessages: true, isFillingCommand: true),
        VoiceNoteEligibility(canSendVoiceMessages: true, isScheduling: true),
        VoiceNoteEligibility(isPrivate: true, isEditing: true),
    ])
    func itIsNotOfferedWhereItCannotWork(_ eligibility: VoiceNoteEligibility) {
        #expect(!eligibility.isOffered)
    }
}
