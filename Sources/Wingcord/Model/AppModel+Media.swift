import AppKit
import Foundation
import WingcordCore

extension AppModel {

    /// Opens the viewer on one attachment, with the rest of the message's media
    /// beside it.
    ///
    /// **The whole message travels, not only what was clicked.** A message with
    /// four screenshots in it is one thing somebody posted, and a lightbox that
    /// has to be closed and reopened to see the second is one people close and
    /// reopen four times.
    ///
    /// Non-media attachments are dropped rather than shown as a box the viewer
    /// cannot fill — see `MediaItem.init?`. That is also why the index has to be
    /// re-derived: an archive sitting between two pictures shifts every position
    /// after it.
    ///
    /// - Parameter posterWidths: The width each attachment was drawn at in the
    ///   transcript, so the viewer can peek the exact rendition already decoded
    ///   and open on the picture instead of on a placeholder. The cache key is
    ///   `(url, pixel size)` and both halves have to match the transcript's.
    /// A file card's Download.
    func downloadAttachment(messageID: MessageID, in channelID: ChannelID, attachmentIndex: Int) {
        // The transcript's copy, or the inspector's — an older file found by
        // search is in no transcript.
        guard let attachments = knownMessage(messageID, in: channelID)?.attachments,
              attachments.indices.contains(attachmentIndex)
        else { return }
        AttachmentDownloads.download(attachments[attachmentIndex], model: self)
    }

    func openMedia(
        messageID: MessageID,
        in channelID: ChannelID,
        attachmentIndex: Int,
        posterWidths: [CGFloat],
        posterURLs: [URL?] = [],
        origin: MediaViewerRequest.Origin = .transcript,
        forwarded: Bool = false,
        startingAt seconds: Double? = nil
    ) {
        // The transcript's copy, or the inspector's — see `knownMessage`.
        guard let message = knownMessage(messageID, in: channelID) else { return }

        // **A forward's files are a gallery of their own**, the forwarded
        // message's, numbered from `MediaSources.forwardedIndexBase` so the
        // flight finds their boxes rather than the message's own.
        let attachments = forwarded ? (message.forwarded?.attachments ?? []) : message.attachments
        let indexBase = forwarded ? MediaSources.forwardedIndexBase : 0
        guard attachments.indices.contains(attachmentIndex) else { return }

        // **A file nothing here can show is downloaded — whatever sits beside
        // it.** The check used to be whether the message had *any* viewable
        // item, so a zip beside a picture opened the picture.
        let clicked = attachments[attachmentIndex]
        guard MediaItem(clicked, posterWidth: Metrics.attachmentThumbnail) != nil else {
            AttachmentDownloads.download(clicked, model: self)
            return
        }

        var items: [MediaItem] = []
        items.reserveCapacity(attachments.count)
        var index = 0
        for (position, attachment) in attachments.enumerated() {
            let width = posterWidths.indices.contains(position)
                ? posterWidths[position]
                : Metrics.attachmentThumbnail
            let poster = posterURLs.indices.contains(position) ? posterURLs[position] : nil
            guard var item = MediaItem(
                attachment, posterWidth: width, posterURL: poster, attachmentIndex: indexBase + position
            ) else { continue }
            // An uploaded GIF is starred under its CDN address, as the chat's
            // own star keys it (`TimelineRowLayout.favorite(for:)`).
            if item.kind == .animated, !attachment.isSpoiler, attachment.playsAsAnimated,
               let url = URL(string: attachment.url), url.scheme == "https" {
                item.favoriteGIF = GIF(
                    url: url, previewURL: URL(string: attachment.proxyURL),
                    width: attachment.width, height: attachment.height
                )
            }
            if position == attachmentIndex { index = items.count }
            items.append(item)
        }

        mediaViewer = MediaViewerRequest(
            items: items,
            index: index,
            messageID: messageID,
            channelID: channelID,
            origin: origin,
            authorName: authorName(of: message, in: channelID),
            sentAt: message.sentAt,
            startsAt: seconds.flatMap { seconds in items.indices.contains(index) ? (items[index].id, seconds) : nil }
        )
    }

    /// An embed's pictures in the viewer: the one clicked, and the card's
    /// others beside it, as Discord opens an embed's image (Alex, 2026-11-16).
    /// Each is shown as a file would be, from the embed's own full-size link.
    func openEmbedPictures(messageID: MessageID, in channelID: ChannelID, pictures: [EmbedPicture], index: Int) {
        guard let message = knownMessage(messageID, in: channelID) else { return }
        var items: [MediaItem] = []
        var start = 0
        for (position, picture) in pictures.enumerated() {
            guard var item = MediaItem(
                picture.attachment, posterWidth: picture.posterWidth, posterURL: picture.posterURL,
                attachmentIndex: picture.sourceIndex
            ) else { continue }
            // An embed's only playable picture is a GIF's MP4: the cards with a
            // player keep their own Play.
            if item.isVideo { item.loopsSilently = true }
            item.favoriteGIF = picture.favorite
            if position == index { start = items.count }
            items.append(item)
        }
        guard !items.isEmpty else { return }
        mediaViewer = MediaViewerRequest(
            items: items,
            index: start,
            messageID: messageID,
            channelID: channelID,
            origin: .transcript,
            authorName: authorName(of: message, in: channelID),
            sentAt: message.sentAt
        )
    }

    /// A game profile's pictures and trailers in the viewer: the one clicked,
    /// and every other one beside it as the gallery (Alex, 2026-11-18).
    ///
    /// An attachment in all but name, as a board's clips are
    /// (`playBoardClips`): the viewer's one item shape, its id distinct only
    /// among these. A still is shown as served — it is IGDB's or the store's,
    /// not the media proxy's — and a trailer plays in the system player.
    func openGameMedia(_ media: [GameMediaItem], index: Int, gameName: String) {
        var items: [MediaItem] = []
        var start = 0
        for (position, entry) in media.enumerated() {
            let attachment: Attachment
            var poster: URL?
            switch entry {
            case .still(let url):
                let name = url.lastPathComponent
                attachment = Attachment(
                    id: AttachmentID(rawValue: UInt64(position + 1)),
                    filename: name.isEmpty ? "Screenshot.jpg" : name,
                    url: url.absoluteString,
                    proxyURL: url.absoluteString,
                    contentType: "image/jpeg"
                )
                poster = url
            case .trailer(let video, let still):
                attachment = Attachment(
                    id: AttachmentID(rawValue: UInt64(position + 1)),
                    filename: "\(gameName) Trailer.mp4",
                    url: video.absoluteString,
                    proxyURL: video.absoluteString,
                    contentType: "video/mp4"
                )
                poster = still
            }
            guard var item = MediaItem(attachment, posterWidth: 640, posterURL: poster, attachmentIndex: position)
            else { continue }
            item.isProxied = false
            if position == index { start = items.count }
            items.append(item)
        }
        guard !items.isEmpty else { return }
        mediaViewer = MediaViewerRequest(
            items: items,
            index: start,
            messageID: nil,
            channelID: nil,
            authorName: gameName,
            sentAt: .now,
            // Opened from the game profile, which is a sheet over everything.
            isAboveSheets: true
        )
    }

    /// Follows a forward's breadcrumb to the original — in a server the reader
    /// is in, a jump; in one they are not, a preview of it first, as Discord's
    /// breadcrumb lurks; in a conversation, the conversation.
    func jumpToForwarded(_ jump: ForwardJump) {
        guard let guildID = jump.guildID else {
            openLink("https://discord.com/channels/@me/\(jump.channelID.rawValue)/\(jump.messageID.rawValue)")
            return
        }
        guard guilds[guildID] == nil else {
            openLink("https://discord.com/channels/\(guildID.rawValue)/\(jump.channelID.rawValue)/\(jump.messageID.rawValue)")
            return
        }
        sessionController.previewGuild(
            guildID,
            channelID: jump.channelID,
            messageID: jump.messageID,
            origin: .forwardBreadcrumb,
            location: "Forward Breadcrumb",
            source: nil
        )
    }

    /// Steps to the next or previous piece of media in the same message.
    func stepMedia(by delta: Int) {
        mediaViewer?.step(delta)
    }

    /// Shows one of the message's pieces of media — the gallery strip's pick.
    func showMedia(at index: Int) {
        guard let request = mediaViewer, request.items.indices.contains(index) else { return }
        mediaViewer?.index = index
    }

    private func authorName(of message: Message, in channelID: ChannelID) -> String {
        let user = users[message.authorID]
        guard let guildID = channelIndex.guildID(of: channelID),
              let member = members[guildID]?[message.authorID]
        else { return user?.preferredName ?? "Unknown" }
        return member.resolvedName(user: user)
    }
}
