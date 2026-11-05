import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// A voice message on the wire: Discord's `eE`, and its attachment writer.
@Suite("Voice messages on the wire")
struct VoiceMessageWireTests {

    private let channel = ChannelID(rawValue: 9)
    private static let sent = #"{"id":"2","channel_id":"9","content":"","author":{"id":"5","username":"a"},"timestamp":"2026-01-01T00:00:00.000000+00:00","flags":8192,"attachments":[]}"#
    private let note = VoiceNoteUpload(durationSeconds: 12.5, waveform: "AAEC")

    @Test("The message says what it is, with no words and the file's two fields")
    func message() async throws {
        let (rest, token) = await RequestRecorder.client(body: Self.sent)
        _ = try await rest.sendMessage(
            in: channel,
            content: "",
            nonce: "1",
            attachments: [
                UploadedAttachment(
                    id: "0",
                    filename: "voice-message.ogg",
                    uploadedFilename: "abc/voice-message.ogg",
                    voice: note
                ),
            ],
            flags: .isVoiceMessage
        )
        let request = try #require(RequestRecorder.requests(for: token).first)
        #expect(request.json?["flags"] as? Int == 8192)
        #expect(request.json?["content"] as? String == "")
        let attachments = try #require(request.json?["attachments"] as? [[String: Any]])
        #expect(attachments.count == 1)
        #expect(attachments[0]["filename"] as? String == "voice-message.ogg")
        #expect(attachments[0]["uploaded_filename"] as? String == "abc/voice-message.ogg")
        #expect(attachments[0]["duration_secs"] as? Double == 12.5)
        #expect(attachments[0]["waveform"] as? String == "AAEC")
    }

    @Test("An ordinary message and an ordinary file say nothing about any of it")
    func ordinary() async throws {
        let (rest, token) = await RequestRecorder.client(body: Self.sent)
        _ = try await rest.sendMessage(
            in: channel,
            content: "hey",
            nonce: "1",
            attachments: [UploadedAttachment(id: "0", filename: "a.png", uploadedFilename: "abc/a.png")]
        )
        let request = try #require(RequestRecorder.requests(for: token).first)
        #expect(request.json?["flags"] == nil)
        let attachments = try #require(request.json?["attachments"] as? [[String: Any]])
        #expect(attachments[0]["duration_secs"] == nil)
        #expect(attachments[0]["waveform"] == nil)
    }

    @Test("The slot's asked for with the same two fields, as Discord's one writer does")
    func slot() async throws {
        let (rest, token) = await RequestRecorder.client(
            body: #"{"attachments":[{"id":0,"upload_url":"https://example.com/up","upload_filename":"abc/voice-message.ogg"}]}"#
        )
        _ = try await rest.createUploadSlots(in: channel, for: [
            UploadRequest(filename: "voice-message.ogg", size: 4_096, voice: note),
        ])
        let request = try #require(RequestRecorder.requests(for: token).first)
        let files = try #require(request.json?["files"] as? [[String: Any]])
        #expect(files[0]["duration_secs"] as? Double == 12.5)
        #expect(files[0]["waveform"] as? String == "AAEC")
        #expect(files[0]["is_clip"] as? Bool == false)
    }

    /// A reply to a voice message says so, rather than "Click to see attachment".
    @Test("A reply quotes a voice message by name")
    func quote() throws {
        let json = #"""
        {"id":"3","channel_id":"9","content":"nice","type":19,"timestamp":"2026-01-01T00:00:00.000000+00:00",
         "author":{"id":"5","username":"a"},
         "message_reference":{"message_id":"2","channel_id":"9"},
         "referenced_message":{"id":"2","channel_id":"9","content":"","flags":8192,
           "author":{"id":"6","username":"b"},"timestamp":"2026-01-01T00:00:00.000000+00:00",
           "attachments":[{"id":"7","filename":"voice-message.ogg","url":"https://cdn/x","proxy_url":"https://cdn/x","size":1}]}}
        """#
        let message = try JSONDecoder().decode(MessageDTO.self, from: Data(json.utf8)).domain
        #expect(message.payload?.reference?.excerpt == MessageReference.voiceMessageExcerpt)
    }

    @Test("A voice note's fields come back as what the row draws from")
    func decoding() throws {
        let json = #"""
        {"id":"3","channel_id":"9","content":"","flags":8192,"timestamp":"2026-01-01T00:00:00.000000+00:00",
         "author":{"id":"5","username":"a"},
         "attachments":[{"id":"7","filename":"voice-message.ogg","url":"https://cdn/x","proxy_url":"https://cdn/x",
           "size":1,"content_type":"audio/ogg","duration_secs":3.2,"waveform":"AAEC"}]}
        """#
        let message = try JSONDecoder().decode(MessageDTO.self, from: Data(json.utf8)).domain
        #expect(message.flags.contains(.isVoiceMessage))
        let attachment = try #require(message.attachments.first)
        #expect(attachment.waveform == "AAEC")
        #expect(attachment.durationSeconds == 3.2)
    }
}
