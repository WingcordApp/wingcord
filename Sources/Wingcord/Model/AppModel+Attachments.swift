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

    /// Stages files for a channel, refusing the ones this account cannot send.
    ///
    /// **Partial success is the answer, not all-or-nothing.** Somebody who drags
    /// six photographs and one video that is over the limit wants the six
    /// photographs; refusing the whole drop because one member of it failed
    /// makes them do the selection again by hand.
    func stageAttachments(_ urls: [URL], in channelID: ChannelID) {
        guard permissionGate.canAttachFiles(in: channelID) else { return }
        let limit = uploadLimit(in: channelID)
        var refusal: AttachmentRefusal?
        var staged: [PendingAttachment] = []
        var room = Self.attachmentCountLimit - (messages(in: channelID)?.attachments.count ?? 0)

        for url in urls {
            guard room > 0 else {
                refusal = .tooMany(limit: Self.attachmentCountLimit)
                break
            }
            // A directory dropped from the Finder is not a file, and neither is
            // a symlink to one that has gone. `isRegularFile` answers both.
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true
            else {
                refusal = .unreadable(filename: url.lastPathComponent)
                continue
            }
            let attachment = PendingAttachment(url: url)
            guard attachment.size > 0 else {
                refusal = .unreadable(filename: attachment.filename)
                continue
            }
            guard attachment.size <= limit else {
                refusal = .tooLarge(
                    filename: attachment.filename, size: attachment.size, limit: limit
                )
                continue
            }
            staged.append(attachment)
            room -= 1
        }

        guard !staged.isEmpty || refusal != nil else { return }
        mutateBox(channelID) { box in
            box.attachments.append(contentsOf: staged)
            box.attachmentRefusal = refusal
        }
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

    func setAttachmentAltText(_ text: String?, for id: PendingAttachment.ID, in channelID: ChannelID) {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        mutateBox(channelID) { box in
            guard let index = box.attachments.firstIndex(where: { $0.id == id }) else { return }
            box.attachments[index].altText = (trimmed?.isEmpty ?? true) ? nil : trimmed
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
