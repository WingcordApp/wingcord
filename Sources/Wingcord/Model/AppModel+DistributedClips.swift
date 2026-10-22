import Foundation
import WingcordCore
import WingcordNet

// MARK: - One moment, from everybody in the call
//
// docs/CLIPS-PRESENCE.md, Phase 7.3. Discord's distributed clips, as its
// `maybeSendRemoteClipTrigger` and `DistributedClipsManager` do them (build
// 643186), under the account's own assignment to `2026-05-distributed-clips`
// (variant 1 is on):
//
//   * **the reader clips** — a clip asked for, while playing a game Discord
//     knows, in a call whose channel is a server's where activity is shown or
//     a conversation of friends: the channel is told, and the moment's id is
//     filed on the clip;
//   * **somebody else clips** — the same game running here and clips armed:
//     this Mac keeps the same moment, filed with the id and who clipped it.
//
// Shared, a clip carries the id, and the player offers the others' views.

extension AppModel {

    /// Whether Discord has given this account distributed clips.
    var distributedClipsEnabled: Bool {
        let hash = MurmurHash3.hash32("2026-05-distributed-clips")
        return experiments.apex.contains { $0.hash == hash && $0.variantID == 1 }
    }

    /// Tells the call the reader just clipped, and files the moment's id.
    func announceClip(_ url: URL) {
        guard distributedClipsEnabled, !LaunchOptions.current.usesDemoFixtures,
              let game = detectedGame, !game.isAddedByHand,
              let channelID = connectedVoiceChannelID, mayAnnounceClips(in: channelID)
        else { return }
        let rest = sessionController.rest
        Task {
            do {
                guard let remoteID = try await rest.sendClipsRemoteTrigger(
                    in: channelID, applicationID: game.id.rawValue
                ), var manifest = ClipLibrary.manifest(for: url) else { return }
                manifest.remoteClipID = remoteID
                ClipLibrary.writeManifest(manifest, for: url)
            } catch {
                Breadcrumbs.record("clips: remote trigger refused")
            }
        }
    }

    /// Discord's rule for where a moment is announced: a conversation whose
    /// every member is a friend, or a server's voice channel in a server the
    /// reader shows their activity in.
    func mayAnnounceClips(in channelID: ChannelID) -> Bool {
        guard let channel = channelIndex[channelID] else { return false }
        if let guildID = channel.guildID {
            return !activityPrivacy.activityRestrictedGuildIDs.contains(guildID)
        }
        let others = channel.recipientIDs.filter { $0 != currentUserID }
        return !others.isEmpty && others.allSatisfy { relationship(with: $0) == .friend }
    }

    /// Somebody in the call clipped: keep the same moment from here, if this
    /// Mac is playing the same game with clips running.
    func receiveRemoteClipTrigger(_ trigger: ClipsRemoteTrigger) {
        guard trigger.userID != currentUserID,
              AppSettings.shared.clipsEnabled, clipRecorder.isArmed,
              let game = detectedGame, game.id.rawValue == trigger.applicationID
        else { return }
        let who = users[trigger.userID]?.preferredName ?? "somebody"
        let length = AppSettings.shared.clipLength.seconds
        Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await clipRecorder.save(
                    seconds: length,
                    to: ClipLibrary.folder,
                    named: ClipLibrary.name(for: game.name),
                    context: clipSaveContext(),
                    remote: (trigger.remoteClipID, trigger.userID.rawValue)
                )
                clipsRevision &+= 1
                // Discord's "Clipped with".
                overlay.showClipFeedback(.saved("Clipped with \(who) — \(url.deletingPathExtension().lastPathComponent)"))
            } catch {
                Breadcrumbs.record("clips: remote clip not kept")
            }
        }
    }
}

// MARK: - The player's side

extension AppModel {

    /// Every view of the moment `item` shows, in its conversation — none when
    /// it is the only one.
    func clipPointsOfView(of item: MediaItem, in channelID: ChannelID?) -> [ClipPointsOfView.View] {
        guard let channelID, let attachment = attachment(item.id, in: channelID) else { return [] }
        return ClipPointsOfView.views(of: attachment, in: messages(in: channelID)?.messages ?? [])
    }

    /// The reader's own clip of that moment, when they have one and have not
    /// shared it in this conversation yet — what "Add your POV" sends.
    func unsharedPointOfView(for views: [ClipPointsOfView.View], of item: MediaItem) -> ClipLibraryItem? {
        guard let remoteID = item.clip?.remoteID, !views.contains(where: { $0.authorID == currentUserID })
        else { return nil }
        if let me = currentUserID, attachmentAuthor(item.id) == me { return nil }
        return ClipLibrary.contents()
            .first { $0.manifest?.remoteClipID == remoteID }
            .map(ClipLibraryItem.init)
    }

    /// Plays another view of the same moment in the viewer's place.
    func switchClipView(to view: ClipPointsOfView.View) {
        guard var request = mediaViewer,
              let item = MediaItem(view.attachment, posterWidth: 640, attachmentIndex: 0)
        else { return }
        request.items[request.index] = item
        request.messageID = view.messageID
        mediaViewer = request
    }

    /// Discord's "Add your POV": the reader's own clip of the moment, shared
    /// as a reply to the one first shared.
    func addPointOfView(_ clip: ClipLibraryItem, to original: ClipPointsOfView.View?, in channelID: ChannelID) {
        let reference = original.map { view in
            MessageReference(
                messageID: view.messageID, channelID: channelID, authorID: view.authorID,
                excerpt: view.attachment.clip?.title ?? "Clip", hasAttachment: true
            )
        }
        shareClips([clip], to: [channelID], comment: "", replyingTo: reference)
    }

    private func attachment(_ id: AttachmentID, in channelID: ChannelID) -> Attachment? {
        for message in messages(in: channelID)?.messages ?? [] {
            if let attachment = message.attachments.first(where: { $0.id == id }) { return attachment }
        }
        return nil
    }

    private func attachmentAuthor(_ id: AttachmentID) -> UserID? {
        guard let channelID = mediaViewer?.channelID else { return nil }
        return messages(in: channelID)?.messages.first { $0.attachments.contains { $0.id == id } }?.authorID
    }
}
