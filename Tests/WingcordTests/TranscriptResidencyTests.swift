import Foundation
import Testing
import WingcordCore
@testable import Wingcord

/// Which transcripts the model may drop to stay within its three, and which
/// it never may — the ones on screen.
@MainActor
@Suite("Transcript residency")
struct TranscriptResidencyTests {

    @Test("The thread beside its channel keeps its transcript while others come and go")
    func sidePanelIsNeverEvicted() throws {
        let model = AppModel()
        DemoFixtures.populate(model)
        let selected = try #require(model.selectedChannelID)
        let sample = try #require(model.messages(in: selected)?.messages.first)
        let thread = ChannelID(rawValue: 900_001)
        model.selectedThreadID = thread
        model.mutateBox(thread) { $0.messages = [sample] }
        // Messages arriving in five other loaded channels — more than the
        // three resident slots hold. The side panel's was the oldest.
        for raw in 900_010 ..< 900_015 {
            model.mutateBox(ChannelID(rawValue: UInt64(raw))) { $0.messages = [sample] }
        }
        #expect(model.messages(in: thread)?.messages.isEmpty == false, "the open thread was evicted")
        #expect(model.messages(in: selected)?.messages.isEmpty == false)
        // A channel nobody is looking at is still let go.
        #expect(model.messages(in: ChannelID(rawValue: 900_010))?.messages.isEmpty == true)
    }

    @Test("Memory pressure keeps every transcript on screen")
    func pressureKeepsTheSidePanel() throws {
        let model = AppModel()
        DemoFixtures.populate(model)
        let selected = try #require(model.selectedChannelID)
        let sample = try #require(model.messages(in: selected)?.messages.first)
        let thread = ChannelID(rawValue: 900_001)
        model.selectedThreadID = thread
        model.mutateBox(thread) { $0.messages = [sample] }
        model.relieveMemoryPressure()
        #expect(model.messages(in: thread)?.messages.isEmpty == false)
        #expect(model.messages(in: selected)?.messages.isEmpty == false)
    }
}
