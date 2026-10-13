import Foundation
import WingcordCore

// MARK: - The composer's `+`
//
// Discord's `channel-attach` menu: which of its rows a conversation offers, and
// the acts behind the ones that are not a file panel — a poll, Use Apps, and a
// time to send at.

extension AppModel {

    /// Whether Create Poll is offered — Discord's `I7` (module `969632`):
    /// anywhere in a conversation, and in a server with `SEND_POLLS` on top of
    /// posting.
    func canPostPolls(in channelID: ChannelID) -> Bool {
        permissionGate.canPostPolls(in: channelID)
    }

    /// Whether Schedule Message is offered.
    ///
    /// **Discord gates it on a user experiment** (`2026-08-scheduled-messages`)
    /// that this client cannot read, so the evidence is the route itself: the
    /// account's scheduled list answered. Then posting here, as Discord's `vK`
    /// asks.
    func canScheduleMessages(in channelID: ChannelID) -> Bool {
        inbox.scheduled != nil && permissionGate.canSend(in: channelID)
    }

    /// Puts the composer into scheduling, or takes it out. Discord's
    /// `changeScheduledMessage` and its bar's Close.
    func setSchedule(_ date: Date?, in channelID: ChannelID) {
        mutateBox(channelID) { $0.scheduledAt = date }
    }

    /// Use Apps: the field becomes `/` and the command list opens on it —
    /// Discord's `setValue("/")`, which replaces whatever was typed.
    func useApps(in channelID: ChannelID) {
        mutateBox(channelID) { $0.draft = "/" }
    }

    /// The composer's Return while it is scheduling.
    ///
    /// The composer empties at once, as it does for a send; the time stays
    /// until Discord has taken the message, as Discord's does. A refusal hands
    /// the words and files back to a composer that is still empty — Discord's
    /// loses them, and nothing is gained by copying that.
    func schedule(_ content: String, from box: MessageBox, at date: Date, in channelID: ChannelID) {
        let attachments = box.attachments
        mutateBox(channelID) {
            $0.draft = ""
            $0.replyingTo = nil
            $0.attachments = []
            $0.attachmentRefusal = nil
        }
        queueScheduled(
            content, at: date, replyingTo: box.replyingTo, pingsRepliedAuthor: box.replyPings,
            attachments: attachments, in: channelID
        ) { [weak self] in
            self?.mutateBox(channelID) { box in
                if box.draft.isEmpty { box.draft = content }
                if box.attachments.isEmpty { box.attachments = attachments }
            }
        }
    }

    /// Hands a message to Discord's queue and leaves scheduling once it is
    /// taken — Discord's `SCHEDULED_MESSAGES_CREATE_SUCCESS` clears the time.
    /// A refusal is said in Discord's words, after `refused` has put back
    /// whatever the caller took away.
    func queueScheduled(
        _ content: String,
        at date: Date,
        replyingTo: MessageID?,
        pingsRepliedAuthor: Bool = true,
        attachments: [PendingAttachment] = [],
        in channelID: ChannelID,
        refused: @escaping () -> Void = {}
    ) {
        Task {
            do {
                try await sessionController.schedule(
                    content, in: channelID, at: date, replyingTo: replyingTo,
                    pingsRepliedAuthor: pingsRepliedAuthor, attachments: attachments
                )
                mutateBox(channelID) { if $0.scheduledAt == date { $0.scheduledAt = nil } }
            } catch {
                refused()
                reportActionFailure(SessionController.schedulingFailure(error, hasNitro: hasNitro))
            }
        }
    }

    /// A message just scheduled joins the inbox's list, which is in hand — the
    /// menu offered scheduling only because it is.
    func noteScheduledMessage(_ message: ScheduledMessage) {
        guard inbox.scheduled != nil else { return }
        inbox.scheduled?.append(message)
        inbox.revision &+= 1
    }

    // MARK: Listening along

    /// The row's words — Discord's "Invite {channel} to Listen to {name}" — or
    /// nil where there is nothing to invite to.
    ///
    /// **Only while the reader's Listening activity is on their status**, which
    /// is what Discord's menu reads, and not in a conversation whose other
    /// person is already in the party.
    func listenAlongInvitationTitle(in channelID: ChannelID) -> String? {
        guard let activity = spotifyActivity, let partyID = activity.party?.id,
              permissionGate.canSend(in: channelID),
              let channel = channelIndex[channelID]
        else { return nil }
        if channel.kind == .directMessage,
           let recipient = channel.recipientIDs.first(where: { $0 != currentUserID }),
           presences[recipient]?.activities?.list.contains(where: { $0.partyID == partyID }) == true
        {
            return nil
        }
        let name = switch channel.kind {
        case .directMessage: "@\(displayName(of: channel))"
        case .groupDirectMessage: displayName(of: channel)
        default: "#\(displayName(of: channel))"
        }
        return "Invite \(name) to Listen to \(activity.name)"
    }

    /// Sends the invitation — a message of its own, drawn at once like any
    /// send, carrying the party the reader is hosting.
    func sendListenAlongInvite(in channelID: ChannelID) {
        guard let activity = spotifyActivity, let partyID = activity.party?.id else { return }
        sessionController.send(
            "",
            in: channelID,
            replyingTo: nil,
            listenAlong: ListenAlongInvite(partyID: partyID, name: activity.name, iconKey: activity.assets?.largeImage)
        )
    }

    // MARK: Polls

    func openPollEditor(in channelID: ChannelID) {
        pollEditor = PollEditorRequest(channelID: channelID)
    }

    /// Post, from the editor: a send like any other, drawn at once and red with
    /// Resend if Discord refuses it — so the poll is never lost with the sheet.
    func postPoll(_ draft: PollDraft, in channelID: ChannelID) {
        sessionController.send("", in: channelID, replyingTo: nil, poll: draft)
    }

    /// Schedule Poll, from the editor. Returns Discord's refusal in its words,
    /// or nil once the poll is queued.
    ///
    /// **Awaited, unlike Post**: a scheduled poll draws nothing in the
    /// transcript to turn red, so the editor stays open until Discord has it —
    /// as Discord's does — and a refusal is shown where the poll still is.
    func schedulePoll(_ draft: PollDraft, at date: Date, in channelID: ChannelID) async -> String? {
        do {
            try await sessionController.schedule("", in: channelID, at: date, poll: draft)
            return nil
        } catch {
            return SessionController.schedulingFailure(error, hasNitro: hasNitro)
        }
    }
}
