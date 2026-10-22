import Foundation
import Testing
@testable import WingcordCore

/// Auto Clips' decision (docs/CLIPS-PRESENCE.md, Phase 7.2): what is worth a
/// clip, what needs company, and that one fight is one clip.
@Suite("Auto Clips policy")
struct AutoClipPolicyTests {

    @Test("A multikill is a clip by itself, named for itself")
    func multikill() throws {
        var policy = AutoClipPolicy()
        let observed = policy.observe(.game(.multikill, name: "Triple Kill"), at: 100)
        let trigger = try #require(observed)
        #expect(trigger.reason.kind == .gameEvent)
        #expect(trigger.reason.name == "Triple Kill")
        #expect(trigger.reason.label == "In-game event")
        #expect(trigger.time == 100)
    }

    @Test("A kill alone is not, but a laugh right after it is — and the kill names it")
    func killAndLaugh() throws {
        var policy = AutoClipPolicy()
        let result1 = policy.observe(.game(.kill, name: "Kill"), at: 10)
        #expect(result1 == nil)
        let observed = policy.observe(.laughter(confidence: 0.7), at: 12)
        let trigger = try #require(observed)
        #expect(trigger.reason.kind == .gameEvent)
        #expect(trigger.reason.name == "Kill")
        #expect(trigger.start == 10)
    }

    @Test("A big laugh is a clip on its own; a weak one is ignored")
    func laughter() throws {
        var policy = AutoClipPolicy()
        let result2 = policy.observe(.laughter(confidence: 0.5), at: 1)
        #expect(result2 == nil)
        let observed = policy.observe(.laughter(confidence: 0.92), at: 2)
        let trigger = try #require(observed)
        #expect(trigger.reason.kind == .laughter)
        #expect(trigger.reason.label == "LOL")
    }

    @Test("Shouting needs company")
    func shouting() throws {
        var policy = AutoClipPolicy()
        let result3 = policy.observe(.shouting(confidence: 0.95), at: 1)
        #expect(result3 == nil)
        let observed = policy.observe(.shouting(confidence: 0.9), at: 3)
        let trigger = try #require(observed)
        #expect(trigger.reason.kind == .shouting)
    }

    @Test("Signals older than the window no longer count")
    func window() {
        var policy = AutoClipPolicy()
        let result4 = policy.observe(.game(.kill, name: "Kill"), at: 0)
        #expect(result4 == nil)
        let result5 = policy.observe(.game(.kill, name: "Kill"), at: 20)
        #expect(result5 == nil)
    }

    @Test("One fight is one clip: nothing more inside the cooldown")
    func cooldown() throws {
        var policy = AutoClipPolicy()
        let first = policy.observe(.game(.multikill, name: "Double Kill"), at: 50)
        #expect(first != nil)
        let result6 = policy.observe(.game(.multikill, name: "Triple Kill"), at: 60)
        #expect(result6 == nil)
        let result7 = policy.observe(.game(.multikill, name: "Quadra Kill"), at: 81)
        #expect(result7 != nil)
    }

    @Test("The two switches hold")
    func switches() {
        var policy = AutoClipPolicy()
        policy.listensForGameEvents = false
        let result8 = policy.observe(.game(.multikill, name: "Ace"), at: 1)
        #expect(result8 == nil)
        policy.listensForEmotion = false
        let result9 = policy.observe(.laughter(confidence: 0.99), at: 2)
        #expect(result9 == nil)
    }

    @Test("Named moments from each game are weighed by name")
    func namedMoments() {
        #expect(AutoClipPolicy.score(.unclassified, name: "Ace") == 1)
        #expect(AutoClipPolicy.score(.unclassified, name: "Round Winning Kill") == 1)
        #expect(AutoClipPolicy.score(.unclassified, name: "Bomb Defused") == 0.6)
        #expect(AutoClipPolicy.score(.unclassified, name: "Ward Placed") == 0.2)
        #expect(AutoClipPolicy.score(.unclassified, name: "Pentakill") == 1)
        #expect(AutoClipPolicy.score(.unclassified, name: "Elder Dragon Steal") == 1)
        #expect(AutoClipPolicy.score(.item, name: "Blink Dagger") == 0)
    }

    @Test("An older sidecar reads as a clip somebody asked for")
    func manifestMethod() throws {
        var manifest = ClipManifest(createdAt: .now, duration: 30)
        #expect(!manifest.isAutoClip)
        manifest.method = .auto
        manifest.autoReason = AutoClipReason(kind: .laughter, name: "LOL", score: 1.1)
        let data = try JSONEncoder().encode(manifest)
        let read = try JSONDecoder().decode(ClipManifest.self, from: data)
        #expect(read.isAutoClip)
        #expect(read.autoReason?.label == "LOL")
        // A sidecar written before the field existed.
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["method"] = nil
        object["autoReason"] = nil
        let old = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(ClipManifest.self, from: old).method == nil)
    }
}

/// Distributed clips (docs/CLIPS-PRESENCE.md, Phase 7.3): the views of one
/// moment, found by the id they share.
@Suite("Clip points of view")
struct ClipPointsOfViewTests {

    private func message(_ id: UInt64, author: UInt64, attachment: UInt64, remoteID: String?) -> Message {
        Message(
            id: MessageID(rawValue: id), channelID: ChannelID(rawValue: 1), authorID: UserID(rawValue: author),
            content: "",
            payload: MessagePayload(attachments: [
                Attachment(
                    id: AttachmentID(rawValue: attachment), filename: "c.mp4", url: "https://x/c.mp4",
                    proxyURL: "https://x/c.mp4", contentType: "video/mp4",
                    clip: AttachmentClip(title: "c", remoteID: remoteID)
                ),
            ])
        )
    }

    @Test("Every view of the moment, oldest first, the first one the original")
    func views() throws {
        let messages = [
            message(30, author: 3, attachment: 300, remoteID: "m"),
            message(10, author: 1, attachment: 100, remoteID: "m"),
            message(20, author: 2, attachment: 200, remoteID: "other"),
        ]
        let original = try #require(messages[1].attachments.first)
        let views = ClipPointsOfView.views(of: original, in: messages)
        #expect(views.map(\.attachment.id.rawValue) == [100, 300])
        #expect(views.first?.isOriginal == true)
        #expect(views.last?.isOriginal == false)
        #expect(views.last?.authorID == UserID(rawValue: 3))
    }

    @Test("A moment only one person shared has no other views")
    func alone() throws {
        let messages = [message(10, author: 1, attachment: 100, remoteID: "m")]
        #expect(ClipPointsOfView.views(of: try #require(messages[0].attachments.first), in: messages).isEmpty)
        let plain = [message(11, author: 1, attachment: 101, remoteID: nil)]
        #expect(ClipPointsOfView.views(of: try #require(plain[0].attachments.first), in: plain).isEmpty)
    }
}
