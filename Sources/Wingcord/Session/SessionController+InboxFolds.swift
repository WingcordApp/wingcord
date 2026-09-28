import Foundation
import WingcordCore
import WingcordNet

/// One inbox group, as a fold is keyed: the server and the channel, or the
/// server's scheduled events.
struct InboxFoldKey: Hashable {
    var guildID: GuildID?
    var channelID: ChannelID?
}

extension SessionController {

    /// Folds or unfolds one inbox group — at once on screen, and in the
    /// account's settings ten seconds after the last fold, which is Discord's
    /// own delay for this write (`FREQUENT_USER_ACTION`). A reader tidying the
    /// inbox folds several groups in a row; they go out as one write.
    func foldInboxGroup(channelID: ChannelID, collapsed: Bool) {
        if collapsed {
            model.inboxCollapse.channels.insert(channelID)
        } else {
            model.inboxCollapse.channels.remove(channelID)
        }
        let guildID = model.channelIndex.guildID(of: channelID)
        scheduleFoldWrite(InboxFold(guildID: guildID, channelID: channelID, collapsed: collapsed))
    }

    /// Folds or unfolds a server's Events group, on the same terms.
    func foldInboxEvents(guildID: GuildID, collapsed: Bool) {
        if collapsed {
            model.inboxCollapse.guildEvents.insert(guildID)
        } else {
            model.inboxCollapse.guildEvents.remove(guildID)
        }
        scheduleFoldWrite(InboxFold(guildID: guildID, channelID: nil, collapsed: collapsed))
    }

    private func scheduleFoldWrite(_ fold: InboxFold) {
        pendingInboxFolds[InboxFoldKey(guildID: fold.guildID, channelID: fold.channelID)] = fold
        inboxFoldWrite?.cancel()
        inboxFoldWrite = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self else { return }
            let folds = Array(pendingInboxFolds.values)
            pendingInboxFolds.removeAll()
            do {
                try await rest.setInboxFolds(folds)
            } catch {
                Self.trace("inbox folds failed: \(Self.describe(error))")
            }
        }
    }
}
