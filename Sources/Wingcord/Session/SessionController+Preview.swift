import Foundation
import WingcordCore
import WingcordNet

extension SessionController {

    /// Starts previewing a server, then opens the message that sent us there.
    ///
    /// **The REST call does not deliver the channels; the socket does.** The 200
    /// carries the guild's own fields and no `channels` array — see
    /// `DiscordREST.lurkGuild`. What arrives a beat later is a `GUILD_CREATE`,
    /// which is the same event a real join produces, so it lands in
    /// `guildAvailable` and populates the index, the roles and the rail with no
    /// code of its own.
    ///
    /// So this waits for the guild to appear rather than for the response. The
    /// wait is bounded and has a real failure: a server can accept the lurk and
    /// still dispatch nothing the client can read, and a spinner with no end is
    /// worse than a page that says it could not open.
    /// - Parameters:
    ///   - channelID: the channel to land on, where the caller has one. **Nil
    ///     for discovery**, which points at a *server* rather than at something
    ///     written in it — there the reader lands wherever the server's own
    ///     first readable channel is, exactly as clicking a rail tile does.
    ///   - recommendationLoadID: the discovery load a card was clicked from.
    ///     Nil everywhere else; see `DiscordREST.lurkGuild`.
    func previewGuild(
        _ guildID: GuildID,
        channelID: ChannelID? = nil,
        messageID: MessageID? = nil,
        origin: GuildPreview.Origin,
        location: String,
        source: String?,
        recommendationLoadID: String? = nil
    ) {
        // Already in it, previewing it, or previewing something else — each is
        // a different answer and none of them is a second lurk.
        if model.guilds[guildID] != nil, model.guildPreview?.guildID != guildID {
            // A server the reader has actually joined needs no preview at all.
            openPreviewedChannel(channelID, messageID: messageID)
            return
        }
        if model.guildPreview?.guildID == guildID {
            openPreviewedChannel(channelID, messageID: messageID)
            return
        }

        model.guildPreview = GuildPreview(guildID: guildID, origin: origin, isStarting: true)
        model.permissionGate.invalidate()

        Task { [weak self] in
            guard let self else { return }
            guard let sessionID = await socket?.currentSessionID else {
                Self.trace("preview \(guildID.rawValue): no gateway session")
                model.guildPreview = nil
                return
            }
            do {
                _ = try await rest.lurkGuild(
                    guildID,
                    sessionID: sessionID,
                    location: location,
                    source: source,
                    recommendationLoadID: recommendationLoadID
                )
            } catch {
                Self.trace("preview \(guildID.rawValue) failed: \(Self.describe(error))")
                model.guildPreview = nil
                model.permissionGate.invalidate()
                // **A refusal here needs words.** The commonest one is the
                // hundred-server cap — which a *lurk* counts against, captured —
                // and a card that appears to do nothing is the worst possible
                // reading of it.
                model.reportActionFailure(Self.discoveryFailure(error))
                return
            }
            guard await waitForGuild(guildID) else {
                Self.trace("preview \(guildID.rawValue): no GUILD_CREATE")
                model.guildPreview = nil
                model.permissionGate.invalidate()
                return
            }
            guard model.guildPreview?.guildID == guildID else { return }
            model.guildPreview?.isStarting = false
            model.permissionGate.invalidate()
            // **Discovery closes HERE, on the answer, not on the click.** It
            // used to close first, and a refused lurk — the hundred-server cap
            // is the commonest one, and it is captured — then left the reader
            // standing in whatever channel was underneath with a notice about a
            // server they could no longer see. A page stays up until the thing
            // it raised has actually happened.
            model.closeDiscovery()
            if channelID == nil {
                // Selected only now, after `GUILD_CREATE` — before it the guild
                // is not in the store and `selectGuild` would land on nothing.
                model.selectGuild(guildID)
            }
            openPreviewedChannel(channelID, messageID: messageID)
        }
    }

    /// Ends a preview and forgets the server.
    ///
    /// **`{"lurking": true}` on the leave route, and the flag is the whole
    /// difference.** The same `DELETE /users/@me/guilds/{id}` without it leaves
    /// a server the reader actually joined. The store is cleared first: the
    /// answer does not change what the reader sees, and a page that stays open
    /// until a round trip finishes reads as a control that did not work.
    func stopPreviewing() {
        guard let preview = model.guildPreview else { return }
        model.guildPreview = nil
        model.permissionGate.invalidate()
        model.forgetPreviewedGuild(preview.guildID)

        Task { [weak self] in
            guard let self else { return }
            do {
                try await rest.leaveGuild(preview.guildID, lurking: true)
            } catch {
                // The socket closing ends the lurk anyway, so a failure here
                // costs nothing that outlives the session.
                Self.trace("end preview \(preview.guildID.rawValue): \(Self.describe(error))")
            }
        }
    }

    /// Joins the server being previewed, for real.
    ///
    /// The same route without `lurker=true`. On success the server sends a
    /// `GUILD_CREATE` for a real membership and a `GUILD_MEMBER_ADD`; the
    /// preview simply stops being one, and nothing is torn down — the reader is
    /// left exactly where they were reading, which is the point of the button.
    func joinPreviewedGuild() {
        guard let preview = model.guildPreview, !model.isJoiningPreviewedGuild else { return }
        model.isJoiningPreviewedGuild = true

        Task { [weak self] in
            guard let self else { return }
            defer { model.isJoiningPreviewedGuild = false }
            do {
                // **No `location`, and the source is the banner's own name.** Both
                // captured, twice, in `join discoverable server.har`: the join
                // from a preview sends `x-context-properties:
                // {"source":"Notice - Lurker Mode"}` and no location at all.
                // This used to send `location: "Preview Mode Banner"`, which was
                // a plausible invention.
                _ = try await rest.joinGuild(preview.guildID, source: "Notice - Lurker Mode")
            } catch {
                Self.trace("join \(preview.guildID.rawValue): \(Self.describe(error))")
                return
            }
            guard model.guildPreview?.guildID == preview.guildID else { return }
            model.guildPreview = nil
            model.permissionGate.invalidate()
            model.railRevision &+= 1
        }
    }

    /// Drops a preview whose session has gone.
    ///
    /// **Called on READY, not on disconnect.** A resume keeps the session id and
    /// therefore keeps the lurk; a fresh READY is a new session, and every lurk
    /// on the old one is already gone server-side. Dropping it on the disconnect
    /// instead would kill a preview that a two-second blip was about to restore.
    func dropPreviewForNewSession() {
        guard let preview = model.guildPreview else { return }
        model.guildPreview = nil
        model.isJoiningPreviewedGuild = false
        model.forgetPreviewedGuild(preview.guildID)
        model.permissionGate.invalidate()
    }

    // MARK: Waiting for the socket to catch up

    /// Polls the store for the guild the lurk subscribed us to.
    ///
    /// A poll rather than a continuation resumed from the event path, and
    /// deliberately: the alternative is a stored continuation that has to be
    /// resumed exactly once from a dispatch site that knows nothing about
    /// previews, and leaking one hangs the caller for the life of the process.
    /// Ten checks at 120 ms is a fifth of a second of latency in the worst case
    /// and no state that can be got wrong.
    func waitForGuild(_ guildID: GuildID) async -> Bool {
        for _ in 0..<10 {
            if model.channelIndex.channelIDs(inGuild: guildID).isEmpty == false { return true }
            try? await Task.sleep(for: .milliseconds(120))
        }
        return model.channelIndex.channelIDs(inGuild: guildID).isEmpty == false
    }

    /// Opens the channel the preview was raised for, on the message it was
    /// raised for.
    ///
    /// **The guild has to be selected as well as the channel**, and that is not
    /// a detail: `selectChannel` sets the channel and nothing else, because
    /// every other caller is already inside the server it belongs to. Arriving
    /// from a game profile is the first path that is not — without this the
    /// transcript changes and the rail and the channel list stay on whatever
    /// server was open before.
    /// Lands the reader in the previewed server.
    ///
    /// **A nil channel is a real caller, not a missing value.** Discovery points
    /// at a server, so it selects the guild and lets `selectGuild` find the
    /// first channel the reader may read — which is the same arithmetic a rail
    /// click uses, rather than a second answer to "where does a server open".
    private func openPreviewedChannel(_ channelID: ChannelID?, messageID: MessageID?) {
        guard let channelID else { return }
        if let guildID = model.channelIndex.guildID(of: channelID) {
            model.selectGuild(guildID)
        }
        if let messageID {
            jumpToMessage(messageID, in: channelID)
        } else {
            model.selectChannel(channelID)
        }
    }
}
