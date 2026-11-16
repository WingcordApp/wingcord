import Foundation
import WingcordCore

extension AppModel {

    // MARK: Raising a preview

    /// Opens a community announcement where it was posted.
    ///
    /// **The reader is usually not in the game's server**, which is the whole
    /// reason this route exists: `/games/{id}/announcements` answers with a
    /// guild id, a channel id and messages from a server nobody has to have
    /// joined. Selecting that channel directly would find no channel in the
    /// index and do nothing at all, which is what a shelf card did before this.
    ///
    /// **Every layer over the window comes down first**, not just the game
    /// profile. The page is usually opened from a tile on somebody's full
    /// profile, so both are up — and the destination is behind both of them.
    /// Dismissing only the page leaves a profile sheet floating over a
    /// transcript it has nothing to do with, which is what this did before.
    func openAnnouncement(
        _ messageID: MessageID?,
        in channelID: ChannelID,
        guildID: GuildID,
        game gameID: ApplicationID
    ) {
        dismissGameProfile()
        profileRequest = nil
        sessionController.previewGuild(
            guildID,
            channelID: channelID,
            messageID: messageID,
            origin: .gameProfile(gameID),
            // Discord's own analytics values for this path, from the capture.
            location: "game profile",
            source: "Game Profile Announcements"
        )
    }

    // MARK: Leaving one

    /// Ends the preview and goes back where it came from.
    ///
    /// **Both halves, in one action.** Ending the lurk without navigating leaves
    /// the reader looking at a channel list that is about to empty; navigating
    /// without ending it leaves a server in the rail nobody can get back to.
    func leavePreview() {
        guard let preview = guildPreview else { return }
        sessionController.stopPreviewing()
        // Back to where the reader was — the server and channel they left,
        // or the conversations when that is where they were.
        if let guildID = preview.returnGuildID, guilds[guildID] != nil {
            selectGuild(guildID)
        } else if preview.returnGuildID == nil {
            selectGuild(nil)
        }
        if let channelID = preview.returnChannelID, channelIndex[channelID] != nil {
            selectChannel(channelID)
        }
        switch preview.origin {
        case .gameProfile(let gameID):
            openGameProfile(gameID)
        case .discovery:
            // The grid the reader left, as they left it.
            discovery = discoveryReturn ?? DiscoveryState()
            discoveryReturn = nil
            sessionController.loadDiscovery()
        case .guildProfile, .forwardBreadcrumb:
            // The server and channel restored above are where these came from.
            break
        }
    }

    /// Looks at a discoverable server from its tag card — Discord's
    /// `LURK_DISCOVERABLE` Join, captured in `join from server tag.har`:
    /// `PUT /guilds/{id}/members/@me?lurker=true&session_id=…`, body `{}`,
    /// `x-context-properties` `{}`, and no location.
    func previewFromGuildProfile(_ guildID: GuildID) {
        profileRequest = nil
        sessionController.previewGuild(guildID, origin: .guildProfile, location: nil, source: nil)
    }

    /// Looks at a discoverable server from an emoji's card — the same preview
    /// as the tag card's Join, captured again in `pressing on emoji join
    /// server preview mode.har`: `PUT …/members/@me?lurker=true`, body `{}`,
    /// `x-context-properties` `{}`.
    func previewFromExpression(_ guildID: GuildID) {
        expressionInfoRequest = nil
        profileRequest = nil
        sessionController.previewGuild(guildID, origin: .guildProfile, location: nil, source: nil)
    }

    /// Joins the server being previewed. The reader stays where they are.
    func joinPreviewedGuild() {
        sessionController.joinPreviewedGuild()
    }

    /// Drops everything a previewed guild put in the store.
    ///
    /// **Not a general "leave a guild" path, and it must not become one.** A
    /// lurk is the only case where a guild's whole subtree can go while the
    /// account keeps every other server — the real leave path is
    /// `guildRemoved`, which also rewrites folders and the guild's own
    /// settings. This clears the tables the preview filled and the selection
    /// pointing into them, and nothing else.
    func forgetPreviewedGuild(_ guildID: GuildID) {
        if selectedGuildID == guildID {
            selectedGuildID = nil
            selectedChannelID = nil
        }
        forgetMessages(in: channelIndex.channelIDs(inGuild: guildID))
        channelIndex.replaceChannels([], inGuild: guildID)
        guilds[guildID] = nil
        roles[guildID] = nil
        members[guildID] = nil
        guildEmojis[guildID] = nil
        guildStickers[guildID] = nil
        railRevision &+= 1
        sidebarRevision &+= 1
        roleRevision &+= 1
        memberRevision &+= 1
        expressionRevision &+= 1
    }

    // MARK: What the chrome draws

    /// Whether this server is being previewed rather than joined.
    ///
    /// Read by the rail, the sidebar and the server menu. One predicate, because
    /// three copies of `guildPreview?.guildID == id` is three places for a
    /// preview to be half-applied.
    func isPreviewing(_ guildID: GuildID?) -> Bool {
        guard let guildID else { return false }
        return guildPreview?.guildID == guildID
    }

    /// Whether the channel on screen belongs to a previewed server.
    var isPreviewingSelectedGuild: Bool { isPreviewing(selectedGuildID) }

    /// The previewed server's rail tile, or nil.
    ///
    /// **Beside `railItems`, not inside it.** The rail is built from the account's
    /// folder order, which a server nobody joined is not in and must not be
    /// added to — that list is a settings payload the client writes back. Discord
    /// pins the preview above the divider instead, where the home entry is, and
    /// this is the value that goes there.
    ///
    /// No badge state: a lurker has no read cursor in this server, so a pip or a
    /// count would be a number about somebody else's unreads.
    var previewRailGuild: RailGuild? {
        guard let preview = guildPreview, !preview.isStarting,
              let guild = guilds[preview.guildID]
        else { return nil }
        return RailGuild(
            id: guild.id,
            name: guild.name,
            iconURL: guild.iconHash.flatMap {
                CDN.guildIcon(guildID: guild.id, hash: $0, side: Metrics.guildTile)
            },
            monogram: guild.monogram,
            mentionCount: 0,
            hasUnread: false,
            isMuted: false,
            isConnectedToVoice: false
        )
    }

    /// Everything the preview banner and the return bar draw, joined once.
    ///
    /// Nil while the lurk is still starting: the banner names the server, and
    /// the name arrives with the `GUILD_CREATE` rather than with the request.
    var guildPreviewPresentation: GuildPreviewPresentation? {
        guard let preview = guildPreview, !preview.isStarting else { return nil }
        let game = preview.originGameID.flatMap { games[$0] }
        return GuildPreviewPresentation(
            guildID: preview.guildID,
            guildName: guilds[preview.guildID]?.name ?? "this server",
            returnTitle: game?.name,
            returnGameID: preview.originGameID,
            returnIconURL: game.flatMap { gameArtURL($0, kind: .mark, side: Metrics.previewReturnIcon) },
            isJoining: isJoiningPreviewedGuild,
            backLabel: preview.origin == .discovery ? "Back to Discovery" : "Back"
        )
    }
}
