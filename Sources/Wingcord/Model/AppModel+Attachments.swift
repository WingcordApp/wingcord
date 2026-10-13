import Foundation
import WingcordCore

// MARK: - Staging files for the next message
//
// The gate is checked HERE, where the act happens, and not only where the tray
// is drawn — `INVARIANTS.md` §5.5. A file dropped on the transcript, a file
// chosen from the picker and a file pasted all arrive through `stage`, so there
// is one place that decides whether this account may send it and one place that
// says why not.

extension AppModel {

    /// How many files one message may carry. Discord's own limit.
    static let attachmentCountLimit = 10

    /// The largest file this account may attach in this channel.
    ///
    /// **Two subscriptions, and the better one wins.** The reader's premium tier
    /// and the server's boost tier both raise the ceiling, and a direct message
    /// has no server — so the boost half is genuinely absent there rather than
    /// zero. See `AttachmentLimits`.
    func uploadLimit(in channelID: ChannelID) -> Int {
        let boost = channelIndex.guildID(of: channelID).flatMap { guilds[$0] }?.premiumTier
        return AttachmentLimits.bytes(forPremium: entitlements.premiumTier, guildBoostTier: boost)
    }

    /// Stages files for a channel, refusing the ones this account cannot send
    /// in Discord's words.
    ///
    /// **Partial success is the answer, not all-or-nothing.** Somebody who drags
    /// six photographs and one video that is over the limit wants the six
    /// photographs; refusing the whole drop because one member of it failed
    /// makes them do the selection again by hand.
    ///
    /// **A picture or a video over the limit is offered Send Compressed**
    /// rather than only refused — or, with Auto-compress Images on, a picture
    /// is compressed at once, without asking.
    func stageAttachments(_ urls: [URL], in channelID: ChannelID) {
        guard permissionGate.canAttachFiles(in: channelID) else { return }
        let limit = uploadLimit(in: channelID)
        let box = messages(in: channelID)
        var refusal: AttachmentRefusal?
        var staged: [PendingAttachment] = []
        var oversized: [URL] = []
        var room = Self.attachmentCountLimit - (box?.attachments.count ?? 0) - (box?.compressingFiles ?? 0)
        var total = box?.attachments.reduce(0) { $0 + $1.size } ?? 0

        for url in urls {
            guard room > 0 else {
                refusal = .tooMany(limit: Self.attachmentCountLimit)
                break
            }
            // A directory dropped from the Finder is not a file, and neither is
            // a symlink to one that has gone: Discord reads both as empty.
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true
            else {
                refusal = .empty
                continue
            }
            let attachment = PendingAttachment(url: url)
            guard attachment.size > 0 else {
                refusal = .empty
                continue
            }
            guard attachment.size <= limit else {
                if MediaCompressor.canCompress(attachment.contentType) {
                    oversized.append(url)
                    room -= 1
                } else {
                    refusal = .tooLarge(limit: limit, premium: entitlements.premiumTier, compressible: [])
                }
                continue
            }
            guard total + attachment.size <= AttachmentLimits.messageTotal else {
                refusal = .totalTooLarge
                continue
            }
            staged.append(attachment)
            total += attachment.size
            room -= 1
        }

        // Auto-compress Images speaks for pictures; a video is still asked about.
        let compressesNow = AppSettings.shared.autoCompressesImages
            ? oversized.filter { MediaCompressor.isPicture($0) }
            : []
        let offered = oversized.filter { !compressesNow.contains($0) }
        if !offered.isEmpty {
            refusal = .tooLarge(limit: limit, premium: entitlements.premiumTier, compressible: offered)
        }
        if !staged.isEmpty || refusal != nil {
            mutateBox(channelID) { box in
                box.attachments.append(contentsOf: staged)
                box.attachmentRefusal = refusal
            }
        }
        compressAttachments(compressesNow, in: channelID)
    }

    /// Send Compressed: each picture or video made small enough, then staged
    /// — "Compressing files..." in the tray meanwhile, and Discord's refusal
    /// for any that cannot be made to fit.
    func compressAttachments(_ urls: [URL], in channelID: ChannelID) {
        guard !urls.isEmpty else { return }
        let limit = uploadLimit(in: channelID)
        let premium = entitlements.premiumTier
        mutateBox(channelID) { box in
            if !(box.attachmentRefusal?.compressible.isEmpty ?? true) { box.attachmentRefusal = nil }
            box.compressingFiles += urls.count
        }
        Task {
            var compressed: [PendingAttachment] = []
            for url in urls {
                if let copy = await MediaCompressor.compress(url, toFit: limit) {
                    compressed.append(PendingAttachment(url: copy))
                }
            }
            let failed = compressed.count < urls.count
            mutateBox(channelID) { box in
                box.compressingFiles -= urls.count
                let room = max(0, Self.attachmentCountLimit - box.attachments.count - box.compressingFiles)
                box.attachments.append(contentsOf: compressed.prefix(room))
                if failed {
                    box.attachmentRefusal = .tooLarge(limit: limit, premium: premium, compressible: [])
                }
            }
        }
    }

    /// Always Compress Images: Auto-compress Images on from now, and these
    /// compressed now.
    func alwaysCompressAttachments(_ urls: [URL], in channelID: ChannelID) {
        AppSettings.shared.autoCompressesImages = true
        compressAttachments(urls, in: channelID)
    }

    func removeAttachment(_ id: PendingAttachment.ID, in channelID: ChannelID) {
        mutateBox(channelID) { $0.attachments.removeAll { $0.id == id } }
    }

    func toggleAttachmentSpoiler(_ id: PendingAttachment.ID, in channelID: ChannelID) {
        mutateBox(channelID) { box in
            guard let index = box.attachments.firstIndex(where: { $0.id == id }) else { return }
            box.attachments[index].isSpoiler.toggle()
        }
    }

    /// Modify Attachment's Save: the name, the description and the spoiler
    /// at once, as Discord's `UPLOAD_ATTACHMENT_UPDATE_FILE` takes them. An
    /// empty name keeps the old one, where Discord's would store the empty
    /// string and upload a file with no name.
    func modifyAttachment(
        _ id: PendingAttachment.ID,
        in channelID: ChannelID,
        filename: String,
        altText: String?,
        isSpoiler: Bool
    ) {
        let name = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = altText?.trimmingCharacters(in: .whitespacesAndNewlines)
        mutateBox(channelID) { box in
            guard let index = box.attachments.firstIndex(where: { $0.id == id }) else { return }
            if !name.isEmpty { box.attachments[index].filename = name }
            box.attachments[index].altText = (description?.isEmpty ?? true) ? nil : description
            box.attachments[index].isSpoiler = isSpoiler
        }
    }

    /// AnonymiseFileNames' button on a tile: the opposite of what it shows,
    /// kept on the file — the plugin's `upload[ANONYMISE_UPLOAD_SYMBOL] = !anonymise`.
    func toggleAttachmentAnonymise(_ id: PendingAttachment.ID, in channelID: ChannelID) {
        let byDefault = AppSettings.shared.anonymisesByDefault
        mutateBox(channelID) { box in
            guard let index = box.attachments.firstIndex(where: { $0.id == id }) else { return }
            box.attachments[index].anonymise = !(box.attachments[index].anonymise ?? byDefault)
        }
    }

    func dismissAttachmentRefusal(in channelID: ChannelID) {
        guard messages(in: channelID)?.attachmentRefusal != nil else { return }
        mutateBox(channelID) { $0.attachmentRefusal = nil }
    }

    /// Whether a drop over this channel should be accepted at all.
    ///
    /// Read by the drop target so a channel the reader may not attach to shows
    /// no highlight — a target that lights up and then silently discards the
    /// file is worse than one that never lit.
    func canAttachFiles(in channelID: ChannelID) -> Bool {
        permissionGate.canAttachFiles(in: channelID)
    }
}
