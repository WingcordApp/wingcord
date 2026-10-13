import Foundation
import Testing
import WingcordCore
@testable import WingcordNet

/// A stage's writes, with Discord's bodies (modules 602146 and 849736).
@Suite("Stages on the wire")
struct StageWireTests {

    private let channel = ChannelID(rawValue: 20)
    private let guild = GuildID(rawValue: 10)
    private static let instance = #"{"id":"5","guild_id":"10","channel_id":"20","topic":"Q&A","privacy_level":2}"#

    @Test("Starting a stage sends the topic and no event")
    func start() async throws {
        let (rest, token) = await RequestRecorder.client(body: Self.instance)
        let stage = try await rest.startStage(inChannel: channel, topic: "Q&A", notifyEveryone: true)
        let request = try #require(RequestRecorder.requests(for: token).first)
        #expect(request.method == "POST")
        #expect(request.path == "/api/v9/stage-instances")
        #expect(request.json?.keys.sorted() == ["channel_id", "privacy_level", "send_start_notification", "topic"])
        #expect(request.json?["send_start_notification"] as? Bool == true)
        #expect(stage?.topic == "Q&A")
    }

    /// Discord's Start Event for a stage event: the event's name is the topic,
    /// and the event is named — as a string, like every id.
    @Test("A stage started for an event names it")
    func startForEvent() async throws {
        let (rest, token) = await RequestRecorder.client(body: Self.instance)
        _ = try await rest.startStage(inChannel: channel, topic: "Q&A", scheduledEventID: 77)
        let request = try #require(RequestRecorder.requests(for: token).first)
        #expect(request.json?["guild_scheduled_event_id"] as? String == "77")
    }

    @Test("Edit Stage sends the topic with the privacy level it has")
    func editTopic() async throws {
        let (rest, token) = await RequestRecorder.client(body: Self.instance)
        _ = try await rest.setStageTopic("Q&A", privacyLevel: .guildOnly, inChannel: channel)
        let request = try #require(RequestRecorder.requests(for: token).first)
        #expect(request.method == "PATCH")
        #expect(request.path == "/api/v9/stage-instances/20")
        #expect(request.json?.keys.sorted() == ["privacy_level", "topic"])
        #expect(request.json?["privacy_level"] as? Int == 2)
    }

    /// After starting, Discord's own step onto the stage: up, the hand down,
    /// and no "is now a speaker." line in the chat.
    @Test("Stepping up silently sends silent, suppress false and a null hand")
    func silentStepUp() async throws {
        let (rest, token) = await RequestRecorder.client()
        try await rest.setSelfStageState(
            inGuild: guild, channelID: channel, suppress: false, requestToSpeakAt: .some(nil), silent: true
        )
        let request = try #require(RequestRecorder.requests(for: token).first)
        #expect(request.path == "/api/v9/guilds/10/voice-states/@me")
        #expect(request.json?["silent"] as? Bool == true)
        #expect(request.json?["suppress"] as? Bool == false)
        #expect(request.json?["request_to_speak_timestamp"] is NSNull)
    }

    @Test("A hand raised sends no silent")
    func handHasNoSilent() async throws {
        let (rest, token) = await RequestRecorder.client()
        try await rest.setSelfStageState(inGuild: guild, channelID: channel, requestToSpeakAt: .some(.now))
        let request = try #require(RequestRecorder.requests(for: token).first)
        #expect(request.json?["silent"] == nil)
        #expect(request.json?["request_to_speak_timestamp"] is String)
    }
}
