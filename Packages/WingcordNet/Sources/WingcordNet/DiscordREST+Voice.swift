import Foundation
import WingcordCore

// MARK: - Calls and the soundboard
//
// **None of these routes is documented.** Every one was read off a live client,
// and the two that matter most are the ones a bot API would never have: a
// direct-message call is started by *ringing* somebody rather than by joining a
// channel, and a soundboard press is a REST call whose audio nobody uploads —
// the server broadcasts the press and every client plays the clip for itself.

extension DiscordREST {

    /// Discord's own six sounds, free to every account.
    ///
    /// **Fetched once and never per channel.** The set is global, it changes
    /// about once a year, and asking for it on every picker open is a request
    /// per open for an answer that cannot have moved.
    public func defaultSoundboardSounds() async throws -> [SoundboardSound] {
        try await get(
            "/soundboard-default-sounds",
            route: "soundboard-default-sounds",
            as: [SoundboardSoundDTO].self
        ).map(\.domain)
    }

    /// One server's own sounds.
    ///
    /// Answers `{items: [...]}` where most list routes answer a bare array, so
    /// the decoder takes both — see `SoundboardListDTO`.
    public func soundboardSounds(inGuild guildID: GuildID) async throws -> [SoundboardSound] {
        try await get(
            "/guilds/\(guildID.rawValue)/soundboard-sounds",
            route: "guilds/{id}/soundboard-sounds",
            as: SoundboardListDTO.self
        ).items.map(\.domain)
    }

    /// Presses a sound in a voice channel.
    ///
    /// **The audio does not go over this.** The server answers 204 and
    /// dispatches `VOICE_CHANNEL_EFFECT_SEND` to everybody in the channel,
    /// each of whom downloads the clip from the CDN and plays it locally. That
    /// is why a sound is in sync to within a network round trip rather than
    /// sample-accurate, and why muting yourself does not silence it.
    ///
    /// `source_guild_id` is required for another server's sound and refused for
    /// a default one, so it is sent only when there is one.
    public func sendSoundboardSound(
        _ sound: SoundboardSound,
        in channelID: ChannelID
    ) async throws {
        struct Body: Encodable {
            var sound_id: String
            var source_guild_id: String?
        }
        _ = try await requestData(
            method: "POST",
            path: "/channels/\(channelID.rawValue)/send-soundboard-sound",
            route: "channels/{id}/send-soundboard-sound",
            body: Body(
                sound_id: sound.id,
                source_guild_id: sound.guildID.map { String($0.rawValue) }
            )
        )
    }

    /// Rings a direct message.
    ///
    /// **A private call has no channel to join.** Joining is
    /// `VOICE_STATE_UPDATE` over the socket, exactly as in a server; what this
    /// adds is the other side's phone actually ringing. Without it the call is
    /// created and nobody is told, which is indistinguishable from a call that
    /// failed.
    ///
    /// `recipients: nil` means everybody in the conversation, which is what the
    /// reference client sends for a one-to-one call.
    public func ring(_ channelID: ChannelID, recipients: [UserID]? = nil) async throws {
        struct Body: Encodable { var recipients: [String]? }
        _ = try await requestData(
            method: "POST",
            path: "/channels/\(channelID.rawValue)/call/ring",
            route: "channels/{id}/call/ring",
            body: Body(recipients: recipients?.map { String($0.rawValue) })
        )
    }

    /// Stops ringing — the caller hanging up before anybody answered, or the
    /// callee declining.
    public func stopRinging(_ channelID: ChannelID, recipients: [UserID]? = nil) async throws {
        struct Body: Encodable { var recipients: [String]? }
        _ = try await requestData(
            method: "POST",
            path: "/channels/\(channelID.rawValue)/call/stop-ringing",
            route: "channels/{id}/call/stop-ringing",
            body: Body(recipients: recipients?.map { String($0.rawValue) })
        )
    }

    /// The clip's bytes.
    ///
    /// **Straight to the CDN, with no token and no rate limiter.** The CDN is a
    /// different host with different limits, and sending the account's
    /// credential to it puts the token in a request that did not need one.
    /// Caching is the caller's: a sound pressed twice in a session must be
    /// fetched once, and that is a decision about a soundboard rather than
    /// about HTTP.
    public func soundboardClip(id: String) async throws -> Data {
        guard let url = CDN.soundboardSound(id: id) else {
            throw Failure.transport("no url for sound \(id)")
        }
        var request = URLRequest(url: url)
        request.setValue("audio/*", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw Failure.transport("no HTTP response")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw Failure.api(status: http.statusCode, code: nil, message: nil)
            }
            return data
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.transport(error.localizedDescription)
        }
    }
}
