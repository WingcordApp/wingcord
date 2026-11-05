import Foundation
import Testing
@testable import Wingcord
@testable import WingcordCore
import WingcordNet
import WingcordVoice

/// A capture that delivers what the test tells it to, when it tells it to.
@MainActor
private final class ScriptedCapture: VoiceNoteCapture {
    enum Failure: Error { case refused }

    var deliver: VoiceNoteFrameSink?
    var failure: Failure?
    var didStop = false

    func start(deliver: @escaping VoiceNoteFrameSink) async throws {
        if let failure { throw failure }
        self.deliver = deliver
    }

    func stop() async { didStop = true }

    func speak(frames: Int, level: Float = 0.2) {
        let frame = [Int16](repeating: 800, count: Int(OpusFormat.voiceFrameCount))
        for _ in 0..<frames {
            frame.withUnsafeBufferPointer { deliver?($0.baseAddress!, level) }
        }
    }
}

@MainActor
@Suite("Recording a voice note", .serialized)
struct VoiceNoteRecorderTests {
    private let here = ChannelID(rawValue: 1)
    private let there = ChannelID(rawValue: 2)

    private func recorder(_ capture: ScriptedCapture, access: Bool = true) -> VoiceNoteRecorder {
        let recorder = VoiceNoteRecorder()
        recorder.makeCapture = { capture }
        recorder.requestAccess = { access }
        return recorder
    }

    /// Lets the recorder's own task run until the capture has been started.
    private func untilStarted(_ capture: ScriptedCapture) async {
        for _ in 0..<500 where capture.deliver == nil {
            try? await Task.sleep(for: .milliseconds(2))
        }
        // The turn after: the recorder takes the answer and moves the flow.
        try? await Task.sleep(for: .milliseconds(10))
    }

    private func settled(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() {
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    @Test func itRecordsAndStopsIntoReview() async throws {
        let capture = ScriptedCapture()
        let recorder = recorder(capture)
        recorder.start(in: here)
        // Nothing moves until the microphone's listening.
        #expect(recorder.flow.phase == .idle)
        await untilStarted(capture)
        #expect(recorder.flow.phase == .recording(here))
        capture.speak(frames: 100)
        #expect(recorder.elapsedSeconds == 2)
        #expect(recorder.level == 0.2)

        recorder.stop()

        #expect(recorder.flow.phase == .review(here))
        let held = try #require(recorder.held)
        #expect(held.file.durationSeconds == 2)
        #expect(FileManager.default.fileExists(atPath: held.file.url.path))
        #expect(held.file.url.lastPathComponent == VoiceMessageLimits.filename)
        #expect(!held.waveform.isEmpty)
        #expect(held.values.count == 100)
        #expect(recorder.stoppedAt != nil)
        await settled { capture.didStop }
        #expect(capture.didStop)
        recorder.discard()
    }

    /// Discord drops these without a word.
    @Test func aSlipOfTheHandLeavesNothing() async {
        let capture = ScriptedCapture()
        let recorder = recorder(capture)
        recorder.start(in: here)
        await untilStarted(capture)
        capture.speak(frames: 10)

        recorder.stop()

        #expect(recorder.flow.phase == .idle)
        #expect(recorder.held == nil)
        #expect(recorder.notice == nil)
    }

    /// A second press while the system's question is up isn't a second recording.
    @Test func aSecondPressWhileStartingIsNothing() async {
        let capture = ScriptedCapture()
        let recorder = recorder(capture)
        var starts = 0
        recorder.makeCapture = {
            starts += 1
            return capture
        }
        recorder.start(in: here)
        recorder.start(in: here)
        recorder.start(in: there)
        await untilStarted(capture)
        #expect(starts == 1)
        #expect(recorder.flow.phase == .recording(here))
        recorder.discard()
    }

    /// Off to another channel while the system's asking: nothing's opened behind them.
    @Test func leavingWhileStartingOpensNothing() async {
        let capture = ScriptedCapture()
        let recorder = recorder(capture)
        recorder.start(in: here)
        recorder.left(here)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(capture.deliver == nil)
        #expect(recorder.flow.phase == .idle)
        // And a press in the next channel still works.
        recorder.start(in: there)
        await untilStarted(capture)
        #expect(recorder.flow.phase == .recording(there))
        recorder.discard()
    }

    @Test func discardingTakesTheFileWithIt() async throws {
        let capture = ScriptedCapture()
        let recorder = recorder(capture)
        recorder.start(in: here)
        await untilStarted(capture)
        capture.speak(frames: 100)
        recorder.stop()
        let file = try #require(recorder.held).file.url

        recorder.discard()

        #expect(recorder.flow.phase == .idle)
        #expect(recorder.held == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func aRefusedMicrophoneLeavesTheComposerAsItWas() async {
        let capture = ScriptedCapture()
        let recorder = recorder(capture, access: false)
        recorder.start(in: here)
        await settled { recorder.notice != nil }
        #expect(recorder.notice == .microphoneRefused)
        #expect(recorder.flow.phase == .idle)
        #expect(capture.deliver == nil)
    }

    @Test func aMicrophoneThatWontStartSaysSo() async {
        let capture = ScriptedCapture()
        capture.failure = .refused
        let recorder = recorder(capture)
        recorder.start(in: here)
        await settled { recorder.notice != nil }
        #expect(recorder.notice == .microphoneSilent)
        #expect(recorder.flow.phase == .idle)
    }

    /// D5: a microphone left running on a channel nobody can see seems wrong.
    @Test func leavingStopsItAndKeepsItThere() async {
        let capture = ScriptedCapture()
        let recorder = recorder(capture)
        recorder.start(in: here)
        await untilStarted(capture)
        capture.speak(frames: 100)

        recorder.left(there)
        #expect(recorder.flow.isRecording)

        recorder.left(here)
        #expect(recorder.flow.phase == .review(here))
        #expect(recorder.flow.phase(in: there) == .idle)
        recorder.discard()
    }

    @Test func aSecondNoteAsksAboutTheFirst() async {
        let capture = ScriptedCapture()
        let recorder = recorder(capture)
        recorder.start(in: here)
        await untilStarted(capture)
        capture.speak(frames: 100)
        recorder.stop()

        recorder.start(in: there)

        #expect(recorder.notice == .heldElsewhere(here, wanted: there))
        #expect(recorder.flow.phase == .review(here))
        #expect(recorder.held != nil)
        recorder.discard()
    }

    @Test func aCallChangingHandsStopsIt() async {
        let capture = ScriptedCapture()
        let recorder = recorder(capture)
        recorder.start(in: here)
        await untilStarted(capture)
        capture.speak(frames: 100)
        recorder.callChanged()
        #expect(recorder.flow.phase == .review(here))
        recorder.discard()
    }

    @Test func aNoteCanOnlyBeTakenOnce() async throws {
        let capture = ScriptedCapture()
        let recorder = recorder(capture)
        recorder.start(in: here)
        await untilStarted(capture)
        capture.speak(frames: 100)
        #expect(recorder.takeForSending() == nil)
        recorder.stop()

        let held = try #require(recorder.takeForSending())

        #expect(recorder.flow.phase == .idle)
        #expect(recorder.takeForSending() == nil)
        // It's the sender's now, and still there.
        #expect(FileManager.default.fileExists(atPath: held.file.url.path))
        try? FileManager.default.removeItem(at: held.file.url.deletingLastPathComponent())
    }

    @Test func aMicrophoneThatNeverDeliversIsNoticed() async {
        let capture = ScriptedCapture()
        let recorder = recorder(capture)
        recorder.start(in: here)
        await untilStarted(capture)
        for _ in 0..<60 where recorder.notice == nil {
            try? await Task.sleep(for: .milliseconds(100))
        }
        #expect(recorder.notice == .microphoneSilent)
        #expect(recorder.flow.phase == .idle)
    }
}

@MainActor
@Suite("Sending a voice note", .serialized)
struct VoiceNoteSendingTests {

    private func demoModel() throws -> (AppModel, ChannelID, ScriptedCapture) {
        let model = AppModel()
        DemoFixtures.populate(model)
        let channelID = try #require(model.selectedChannelID)
        let capture = ScriptedCapture()
        model.voiceRecorder.makeCapture = { capture }
        model.voiceRecorder.requestAccess = { true }
        return (model, channelID, capture)
    }

    private func hold(_ model: AppModel, in channelID: ChannelID, _ capture: ScriptedCapture) async {
        model.startVoiceNote(in: channelID)
        for _ in 0..<500 where capture.deliver == nil {
            try? await Task.sleep(for: .milliseconds(2))
        }
        try? await Task.sleep(for: .milliseconds(10))
        capture.speak(frames: 150)
        model.voiceRecorder.stop()
    }

    @Test func itGoesAsAMessageOfItsOwnAndLeavesTheWords() async throws {
        let (model, channelID, capture) = try demoModel()
        model.mutateBox(channelID) { $0.draft = "words I was typing" }
        await hold(model, in: channelID, capture)

        model.sendVoiceNote(in: channelID)

        let box = try #require(model.messages(in: channelID))
        let entry = try #require(box.outbox.last)
        #expect(entry.request.isVoiceMessage)
        #expect(entry.request.content.isEmpty)
        #expect(!entry.isUpload)
        #expect(entry.echo.flags.contains(.isVoiceMessage))
        let attachment = try #require(entry.echo.attachments.first)
        #expect(attachment.filename == VoiceMessageLimits.filename)
        #expect(attachment.contentType == "audio/ogg")
        #expect(attachment.durationSeconds == 3)
        #expect(attachment.waveform?.isEmpty == false)
        #expect(entry.files.first?.voice?.durationSeconds == 3)
        // What was typed is still there, and the composer's itself again.
        #expect(box.draft == "words I was typing")
        #expect(model.voiceRecorder.flow.phase == .idle)
        #expect(model.voiceRecorder.held == nil)
    }

    @Test func itTakesTheReplyWithIt() async throws {
        let (model, channelID, capture) = try demoModel()
        let replied = try #require(model.messages(in: channelID)?.messages.last?.id)
        model.mutateBox(channelID) { $0.replyingTo = replied }
        await hold(model, in: channelID, capture)

        model.sendVoiceNote(in: channelID)

        let box = try #require(model.messages(in: channelID))
        #expect(box.outbox.last?.request.replyingTo == replied)
        #expect(box.replyingTo == nil)
    }

    @Test func nothingHeldIsNothingSent() throws {
        let (model, channelID, _) = try demoModel()
        let before = model.messages(in: channelID)?.outbox.count ?? 0
        model.sendVoiceNote(in: channelID)
        #expect((model.messages(in: channelID)?.outbox.count ?? 0) == before)
    }

    @Test func aNoteHeldElsewhereIsNotSentFromHere() async throws {
        let (model, channelID, capture) = try demoModel()
        await hold(model, in: channelID, capture)
        let other = ChannelID(rawValue: 999)
        model.sendVoiceNote(in: other)
        #expect(model.voiceRecorder.flow.phase == .review(channelID))
        model.discardVoiceNote()
    }

    /// `voice-message.ogg` gives nothing away, and a client may know it by that name.
    @Test func itKeepsItsNameWhateverAnonymiseSays() throws {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "wingcord.tests.\(UUID())")!)
        settings.anonymisesFileNames = true
        settings.anonymisesByDefault = true
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(VoiceMessageLimits.filename)
        try Data([1, 2, 3]).write(to: url)

        var note = PendingAttachment(url: url)
        note.voice = VoiceNoteUpload(durationSeconds: 1, waveform: "AA==")
        let picture = PendingAttachment(url: url)

        #expect(!note.isAnonymised(by: settings))
        #expect(picture.isAnonymised(by: settings))
        #expect(PendingAttachment.anonymising([note], settings: settings).first?.filename == VoiceMessageLimits.filename)
        #expect(note.uploadRequest.voice?.waveform == "AA==")
    }

    // MARK: Where it's offered

    @Test func itIsOfferedInAConversationAndAChannel() throws {
        let (model, channelID, _) = try demoModel()
        #expect(model.canRecordVoiceNote(in: channelID))
        let conversation = try #require(model.channelIndex.privateChannelIDs().first)
        #expect(model.canRecordVoiceNote(in: conversation))
    }

    @Test func itIsNotOfferedInAForum() throws {
        let (model, _, _) = try demoModel()
        let guildID = try #require(model.selectedGuildID)
        let forum = try #require(model.channelIndex.channelIDs(inGuild: guildID).first {
            model.channelIndex[$0]?.name == "bug-reports"
        })
        #expect(!model.canRecordVoiceNote(in: forum))
    }

    @Test func itIsNotOfferedWhileEditingOrWithFilesOrASchedule() throws {
        let (model, channelID, _) = try demoModel()
        model.mutateBox(channelID) { $0.scheduledAt = .now.addingTimeInterval(600) }
        #expect(!model.canRecordVoiceNote(in: channelID))
        model.mutateBox(channelID) { $0.scheduledAt = nil }
        #expect(model.canRecordVoiceNote(in: channelID))
    }

    // MARK: How it's named

    @Test func aPreviewCallsItAVoiceMessage() throws {
        let (model, channelID, _) = try demoModel()
        let mine = try #require(model.currentUserID)
        let note = Message(
            id: MessageID(rawValue: 1 << 22),
            channelID: channelID,
            authorID: UserID(rawValue: 77),
            flags: .isVoiceMessage,
            payload: MessagePayload(attachments: [
                Attachment(
                    id: AttachmentID(rawValue: 5),
                    filename: "voice-message.ogg",
                    url: "https://cdn/x",
                    proxyURL: "https://cdn/x",
                    contentType: "audio/ogg",
                    waveform: "AAEC",
                    durationSeconds: 4
                ),
            ])
        )
        #expect(model.previewLine(for: note) == "Voice message")
        var own = note
        own.authorID = mine
        #expect(model.previewLine(for: own) == "You: Voice message")
        #expect(AppModel.excerpt(of: note) == "Voice message")
    }

    @Test func voiceOverSaysHowLong() {
        #expect(VoiceNoteWords.spoken(seconds: 12) == "Voice message, 12 seconds")
        #expect(VoiceNoteWords.spoken(seconds: 1) == "Voice message, 1 second")
        #expect(VoiceNoteWords.spoken(seconds: 60) == "Voice message, 1 minute")
        #expect(VoiceNoteWords.spoken(seconds: 125) == "Voice message, 2 minutes 5 seconds")
        // A note under half a second can't exist, but a message can say anything.
        #expect(VoiceNoteWords.spoken(seconds: 0.2) == "Voice message, 1 second")
    }
}

@MainActor
@Suite("Playing a voice note", .serialized)
struct VoiceNotePlayerTests {

    /// Seconds of silence, in the real format, so a test run stays quiet.
    private func silence(seconds: Int) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(VoiceMessageLimits.filename)
        let recording = try VoiceNoteRecording(url: url)
        let frame = [Int16](repeating: 0, count: Int(OpusFormat.voiceFrameCount))
        for _ in 0..<(seconds * 50) {
            frame.withUnsafeBufferPointer { recording.ingest($0.baseAddress!, level: 0) }
        }
        _ = try recording.finish()
        return url
    }

    private func defaults() -> UserDefaults {
        let name = "voice-note-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private let first = AttachmentID(rawValue: 101)
    private let second = AttachmentID(rawValue: 102)

    @Test func itPlaysAndPausesInPlace() throws {
        let url = try silence(seconds: 2)
        let player = VoiceNotePlayer(defaults: defaults())
        #expect(player.position(of: first) == nil)

        player.toggle(first, source: url, duration: 2)
        #expect(player.current == first)
        #expect(player.isPlaying)

        player.toggle(first, source: url, duration: 2)
        #expect(player.current == first)
        #expect(!player.isPlaying)
        #expect(player.position(of: first) != nil)
        player.stop()
        #expect(player.current == nil)
    }

    @Test func oneAtATimeAndEachKeepsItsPlace() throws {
        let url = try silence(seconds: 2)
        let player = VoiceNotePlayer(defaults: defaults())
        player.play(first, source: url, duration: 2)
        player.play(second, source: url, duration: 2)
        #expect(player.current == second)
        #expect(player.isPlaying)
        // The first's been played, so it reads as played, not as untouched.
        #expect(player.position(of: first) != nil)
        #expect(player.playback.leftAt[first] != nil)
        player.stop()
        #expect(player.playback.leftAt.isEmpty)
    }

    @Test func aPressOnTheBarsPlaysFromThere() throws {
        let url = try silence(seconds: 4)
        let player = VoiceNotePlayer(defaults: defaults())
        player.play(first, source: url, duration: 4, from: 0.5)
        #expect(player.isPlaying)
        #expect(player.position == 2)
        player.seek(toFraction: 0.25)
        #expect(player.position == 1)
        player.stop()
    }

    @Test func theSpeedSteppingIsDiscordsAndRemembered() {
        let store = defaults()
        let player = VoiceNotePlayer(defaults: store)
        #expect(player.rate == 1)
        player.cycleRate(defaults: store)
        #expect(player.rate == 1.5)
        player.cycleRate(defaults: store)
        #expect(player.rate == 2)
        player.cycleRate(defaults: store)
        #expect(player.rate == 0.75)
        player.cycleRate(defaults: store)
        #expect(player.rate == 1)
        player.cycleRate(defaults: store)
        #expect(VoiceNotePlayer(defaults: store).rate == 1.5)
    }

    @Test func aNoteThatWontComeDownCanBeRetried() async throws {
        let player = VoiceNotePlayer(defaults: defaults())
        let nowhere = try #require(URL(string: "http://127.0.0.1:9/nothing.ogg"))
        player.play(first, source: nowhere, duration: 2)
        #expect(player.isLoading)
        for _ in 0..<200 where player.isLoading {
            try? await Task.sleep(for: .milliseconds(25))
        }
        #expect(!player.isLoading)
        #expect(player.failed.contains(first))
        #expect(player.current == nil)
        // Pressing again is the retry, and takes the mark away while it tries.
        player.play(first, source: nowhere, duration: 2)
        #expect(!player.failed.contains(first))
        player.stop()
    }

    /// The path every note from somebody else takes: down once, then played from the copy.
    @Test func aNoteComesDownOnceAndPlaysFromTheCopy() async throws {
        let file = try silence(seconds: 1)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        VoiceNoteDownloadStub.set(body: try Data(contentsOf: file))
        URLProtocol.registerClass(VoiceNoteDownloadStub.self)
        defer { URLProtocol.unregisterClass(VoiceNoteDownloadStub.self) }
        let id = AttachmentID(rawValue: .random(in: 1_000_000...UInt64.max))
        let source = try #require(URL(string: "https://voice-note-stub.invalid/voice-message.ogg"))
        let player = VoiceNotePlayer(defaults: defaults())

        player.play(id, source: source, duration: 1)
        #expect(player.isLoading)
        #expect(!player.isPlaying)
        for _ in 0..<200 where player.isLoading {
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(!player.isLoading)
        #expect(player.isPlaying)
        #expect(player.current == id)
        let copy = try #require(VoiceNoteCache.url(for: id))
        defer { VoiceNoteCache.remove(copy) }
        #expect(try Data(contentsOf: copy) == Data(contentsOf: file))

        player.stop()
        player.play(id, source: source, duration: 1)
        // Straight from the copy, with nothing to wait for.
        #expect(!player.isLoading)
        #expect(player.isPlaying)
        #expect(VoiceNoteDownloadStub.requests == 1)
        player.stop()
    }

    @Test func aBadCopyIsThrownAwayOnlyIfItIsOurs() throws {
        let file = try silence(seconds: 1)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        // A recording still on its way isn't the cache's to delete.
        VoiceNoteCache.remove(file)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func anEchoBecomesTheRealThingWithoutLosingItsPlace() throws {
        let url = try silence(seconds: 2)
        let player = VoiceNotePlayer(defaults: defaults())
        player.play(first, source: url, duration: 2)
        player.rename(first, to: second)
        #expect(player.current == second)
        player.stop()
    }

    @Test func itsDrawnStateFollows() throws {
        var playback = VoiceNotePlayback()
        #expect(playback.position(of: first) == nil)
        playback.current = first
        playback.position = 1.5
        #expect(playback.position(of: first) == 1.5)
        playback.leftAt[second] = 0.5
        #expect(playback.position(of: second) == 0.5)
    }
}

@MainActor
@Suite("A voice note's row")
struct VoiceNoteRowTests {

    private func note(seconds: Double, waveform: String? = "AAEC/w==") -> WingcordCore.Attachment {
        WingcordCore.Attachment(
            id: AttachmentID(rawValue: 3),
            filename: "voice-message.ogg",
            url: "https://cdn.discordapp.com/attachments/1/3/voice-message.ogg",
            proxyURL: "https://media.discordapp.net/attachments/1/3/voice-message.ogg",
            contentType: "audio/ogg",
            size: 4_096,
            waveform: waveform,
            durationSeconds: seconds
        )
    }

    private func slot(_ seconds: Double, width: CGFloat = 800, look: VoiceNoteLook = .capsule) throws -> (AttachmentSlot, VoiceNoteSlot) {
        let slot = TimelineLayoutEngine.voiceSlot(
            note(seconds: seconds), origin: CGPoint(x: 40, y: 10), availableWidth: width, look: look
        )
        return (slot, try #require(slot.voice))
    }

    @Test func aLongerNoteIsWider() throws {
        let short = try slot(1).0.rect.width
        let middle = try slot(20).0.rect.width
        let long = try slot(45).0.rect.width
        #expect(short < middle)
        #expect(middle < long)
        #expect(try slot(600).0.rect.width == long)
    }

    @Test(arguments: [0.5, 3, 45, 600])
    func everythingSitsInsideIt(seconds: Double) throws {
        let (slot, voice) = try slot(seconds)
        for part in [voice.disc, voice.barsRect, voice.timeRect, voice.pill] {
            #expect(slot.rect.contains(part))
        }
        #expect(voice.disc.maxX < voice.barsRect.minX)
        #expect(voice.barsRect.maxX < voice.timeRect.minX)
        #expect(voice.timeRect.maxX <= voice.pill.minX)
        #expect(voice.bars.count == VoiceWaveform.barCount(forWidth: voice.barsRect.width))
    }

    @Test func aNarrowPanelTakesBarsAwayRatherThanOverflowing() throws {
        let (slot, voice) = try slot(600, width: 260)
        #expect(slot.rect.width <= 260)
        #expect(voice.bars.count < VoiceWaveform.barCount(forWidth: 290))
        #expect(voice.barsRect.maxX < voice.timeRect.minX)
    }

    @Test func noWaveformStillDrawsAndStillPlays() throws {
        let (slot, voice) = try slot(5)
        _ = slot
        let bare = TimelineLayoutEngine.voiceSlot(
            note(seconds: 5, waveform: nil), origin: .zero, availableWidth: 800
        )
        #expect(bare.voice?.bars.allSatisfy { $0 == 0 } == true)
        #expect(bare.voice?.source == voice.source)
    }

    @Test func aPressOnTheBarsIsAFraction() throws {
        let (_, voice) = try slot(20)
        #expect(voice.fraction(atX: voice.barsRect.minX) == 0)
        #expect(voice.fraction(atX: voice.barsRect.maxX) == 1)
        #expect(voice.fraction(atX: voice.barsRect.midX) == 0.5)
        #expect(voice.fraction(atX: -100) == 0)
        #expect(voice.fraction(atX: 10_000) == 1)
    }

    @Test func inABubbleTheBubbleIsItsGround() throws {
        let capsule = try slot(10)
        let bare = try slot(10, look: .bubble)
        #expect(!capsule.1.isBare)
        #expect(bare.1.isBare)
        #expect(bare.0.rect.height < capsule.0.rect.height)
        #expect(!bare.1.isOnAccent)
        #expect(try slot(10, look: .accentBubble).1.isOnAccent)
    }

    @Test func thePillSaysDiscordsNumbers() {
        #expect(TimelineRowPainter.voiceRateLabel(0.75) == ".75×")
        #expect(TimelineRowPainter.voiceRateLabel(1) == "1×")
        #expect(TimelineRowPainter.voiceRateLabel(1.5) == "1.5×")
        #expect(TimelineRowPainter.voiceRateLabel(2) == "2×")
    }
}

/// Answers a voice note's download from memory.
private nonisolated final class VoiceNoteDownloadStub: URLProtocol, @unchecked Sendable {
    private static let state = NSLock()
    nonisolated(unsafe) private static var body = Data()
    nonisolated(unsafe) private static var count = 0

    static func set(body: Data) {
        state.withLock {
            self.body = body
            count = 0
        }
    }

    static var requests: Int { state.withLock { count } }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "voice-note-stub.invalid"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.state.withLock {
            Self.count += 1
            return Self.body
        }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
