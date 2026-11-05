import AppKit
import SwiftUI
import Testing
import WingcordCore
@testable import Wingcord

/// The composer's voice note, as far as it can be checked with nothing on screen.
///
/// **Only the resting states are drawn.** A live `TimelineView` never lets an offscreen
/// `NSHostingView` finish measuring: the run hangs in `fittingSize`, so the bars themselves
/// are checked in the demo, on the display's own clock.
@MainActor
@Suite("The composer with a voice note, offscreen", .serialized)
struct ComposerVoiceRenderTests {

    private func composer(_ note: ComposerVoiceNote?, inline: Bool, shape: ChromeShape) -> some View {
        Composer(
            channelName: "faq",
            shape: shape,
            inlineControls: inline,
            canSend: true,
            text: .constant("what I was typing"),
            attachActions: ComposerAttachActions(uploadFile: {}),
            voiceNote: note
        )
    }

    /// The mic costs the field nothing but its own width, and no height.
    @Test(
        "The mic sits in every arrangement without moving the bar",
        arguments: [
            ("messages", false, ChromeShape.pill),
            ("pill", true, ChromeShape.pill),
            ("boxy", true, ChromeShape.boxy),
        ]
    )
    func arrangements(name: String, inline: Bool, shape: ChromeShape) throws {
        let without = try SurfaceRender.render(
            composer(nil, inline: inline, shape: shape),
            named: "voice-composer-\(name)-none",
            width: 620
        )
        let with = try SurfaceRender.render(
            composer(ComposerVoiceNote(isOffered: true), inline: inline, shape: shape),
            named: "voice-composer-\(name)-idle",
            width: 620
        )
        #expect(with.size == without.size)
        #expect(with.ink > 0)
    }

    @Test func theLayoutLeavesTheBarsRoom() {
        let messages = ComposerVoiceLayout.messages
        #expect(messages.reviewReserve > messages.recordingReserve)
        // Stop's at the end, where the send disc goes, and takes that disc's size.
        #expect(messages.recordingReserve == MessagesSendButton.side + ComposerVoiceLayout.barsGap)
        let inline = ComposerVoiceLayout.inline
        #expect(inline.reviewReserve == inline.recordingReserve)
        #expect(ComposerVoiceLayout.reviewMinX < ComposerVoiceLayout.liveMinX)
    }
}
