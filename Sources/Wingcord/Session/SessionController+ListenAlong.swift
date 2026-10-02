import AppKit
import Foundation
import WingcordCore
import WingcordNet

// MARK: - Listening along
//
// Discord's listen-along (`655116`'s `ea` and its stops): the reader's own
// Spotify plays the host's track from where the host is, follows them to the
// next one, and lets go when either of them stops. It needs Premium — Spotify
// takes no player commands from a free account — and a device to play on, which
// may mean starting Spotify and waiting for it to appear.

extension SessionController {

    /// Discord's two refusals, in its words.
    static let listenAlongNeedsPremium =
        "Sorry pal, looks like you aren't a Spotify Premium member! Premium members are able to listen along with other Spotify listeners."
    static let spotifyNotDetected = "Spotify is not detected"

    /// Starts listening along with somebody's Spotify session.
    func listenAlong(with hostID: UserID) {
        guard let session = hostSession(hostID), let client = spotifyClients.values.first else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                guard try await client.isPremium() else {
                    model.reportActionFailure(Self.listenAlongNeedsPremium)
                    return
                }
                let device = try await playableDevice(on: client)
                try await play(session, on: client, device: device)
                model.listeningAlong = ListeningAlong(
                    hostID: hostID,
                    partyID: session.partyID,
                    trackID: session.trackID,
                    startedAt: session.startedAt
                )
                publishPresence()
            } catch {
                Self.trace("listen along failed: \(Self.describe(error))")
                model.reportActionFailure(Self.describe(error))
            }
        }
    }

    /// The host's presence moved — a new track, a seek, or gone.
    func listenAlongHostMoved() {
        guard let along = model.listeningAlong else { return }
        guard let session = hostSession(along.hostID), session.partyID == along.partyID else {
            // **Discord's `j`**: a host whose session is gone gets five
            // minutes to come back before the reader is let go.
            if listenAlongHostGrace == nil {
                listenAlongHostGrace = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(300))
                    guard !Task.isCancelled else { return }
                    self?.stopListeningAlong()
                }
            }
            return
        }
        listenAlongHostGrace?.cancel()
        listenAlongHostGrace = nil
        guard session.trackID != along.trackID || session.startedAt != along.startedAt,
              let client = spotifyClients.values.first
        else { return }
        model.listeningAlong?.trackID = session.trackID
        model.listeningAlong?.startedAt = session.startedAt
        Task { [weak self] in
            guard let self else { return }
            do {
                try await play(session, on: client, device: try await playableDevice(on: client))
            } catch {
                Self.trace("listen along follow failed: \(Self.describe(error))")
            }
        }
    }

    /// The reader's own player moved. Off the host's track, or stopped, is the
    /// reader leaving — five seconds after, unless it comes back (Discord's
    /// `Y`).
    func listenAlongPlayerMoved(_ playing: SpotifyNowPlaying?) {
        guard let along = model.listeningAlong else { return }
        if let playing, playing.item.id == along.trackID {
            listenAlongDrift?.cancel()
            listenAlongDrift = nil
            return
        }
        guard listenAlongDrift == nil else { return }
        listenAlongDrift = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.stopListeningAlong()
        }
    }

    func stopListeningAlong() {
        listenAlongHostGrace?.cancel()
        listenAlongDrift?.cancel()
        listenAlongHostGrace = nil
        listenAlongDrift = nil
        guard model.listeningAlong != nil else { return }
        model.listeningAlong = nil
        publishPresence()
    }

    // MARK: Pieces

    private struct HostSession {
        var partyID: String
        var trackID: String
        var type: String
        var startedAt: Date
    }

    /// What the host is playing that can be followed: a Spotify party with a
    /// track to sync to.
    private func hostSession(_ hostID: UserID) -> HostSession? {
        guard let activity = model.presences[hostID]?.activities?.list.first(where: {
            $0.kind == .listening && SpotifyListening.isSpotifyParty($0.partyID)
        }), let partyID = activity.partyID, let trackID = activity.syncID
        else { return nil }
        return HostSession(partyID: partyID, trackID: trackID, type: "track", startedAt: activity.startedAt ?? .now)
    }

    private func play(_ session: HostSession, on client: SpotifyPlayerClient, device: SpotifyDevice) async throws {
        let position = Int(Date.now.timeIntervalSince(session.startedAt) * 1000)
        try await client.play(itemID: session.trackID, type: session.type, positionMs: position, deviceID: device.id)
    }

    /// Somewhere to play: the active device, else a computer, else Spotify
    /// started here and waited for — Discord's `dM`, with its 30 seconds.
    private func playableDevice(on client: SpotifyPlayerClient) async throws -> SpotifyDevice {
        func pick(_ devices: [SpotifyDevice]) -> SpotifyDevice? {
            devices.first { $0.isActive && !$0.isRestricted }
                ?? devices.first { $0.type == "Computer" && !$0.isRestricted }
        }
        if let device = pick(try await client.devices()) { return device }
        guard let spotify = URL(string: "spotify:"), NSWorkspace.shared.urlForApplication(toOpen: spotify) != nil else {
            throw DiscordREST.Failure.transport(Self.spotifyNotDetected)
        }
        NSWorkspace.shared.open(spotify)
        for _ in 0..<30 {
            try await Task.sleep(for: .seconds(1))
            if let device = pick(try await client.devices()) { return device }
        }
        throw DiscordREST.Failure.transport(Self.spotifyNotDetected)
    }
}
