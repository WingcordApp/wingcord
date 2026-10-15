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
        posterWidths: [CGFloat]
    ) {
        // The transcript's copy, or the inspector's — see `knownMessage`.
        guard let message = knownMessage(messageID, in: channelID) else { return }

        let attachments = message.attachments
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
            guard let item = MediaItem(attachment, posterWidth: width) else { continue }
            if position == attachmentIndex { index = items.count }
            items.append(item)
        }

        mediaViewer = MediaViewerRequest(
            items: items,
            index: index,
            authorName: authorName(of: message, in: channelID),
            sentAt: message.sentAt
        )
    }

    /// Steps to the next or previous piece of media in the same message.
    func stepMedia(by delta: Int) {
        mediaViewer?.step(delta)
    }

    private func authorName(of message: Message, in channelID: ChannelID) -> String {
        let user = users[message.authorID]
        guard let guildID = channelIndex.guildID(of: channelID),
              let member = members[guildID]?[message.authorID]
        else { return user?.preferredName ?? "Unknown" }
        return member.resolvedName(user: user)
    }
}
