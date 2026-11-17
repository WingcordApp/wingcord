import AppKit
import WingcordCore
import WingcordNet

// MARK: - Friend Anniversaries' two buttons

extension SessionController {

    /// Discord's "Celebrate the moment with a GIF": the reader's words, if
    /// any, then the GIF, in their conversation, without leaving the Friends
    /// page (the modal's `sendMessage` twice, in that order).
    func sendAnniversaryGIF(_ gif: GIF, message: String, to userID: UserID) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let channelID = try await conversation(with: userID)
                let words = message.trimmingCharacters(in: .whitespacesAndNewlines)
                let nonce = Self.nonce()
                if !words.isEmpty {
                    let sent = try await rest.sendMessage(in: channelID, content: words, nonce: nonce + "0")
                    if model.messages(in: channelID)?.messages.isEmpty == false { receiveOwn(sent, in: channelID) }
                }
                let sent = try await rest.sendMessage(in: channelID, content: gif.url.absoluteString, nonce: nonce + "1")
                if model.messages(in: channelID)?.messages.isEmpty == false { receiveOwn(sent, in: channelID) }
                model.reportSuccess("GIF Sent")
            } catch {
                model.reportActionFailure(Self.reason(for: error, verb: "send the GIF"))
            }
        }
    }

    /// **Gift**: Nitro is bought on Discord, which this client never does, so
    /// the conversation with them opens on Discord's site, where the composer's
    /// gift button has them already chosen.
    func giftFriend(_ userID: UserID) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let channelID = try await conversation(with: userID)
                if let url = URL(string: "https://discord.com/channels/@me/\(channelID.rawValue)") {
                    NSWorkspace.shared.open(url)
                }
            } catch {
                model.reportActionFailure(Self.reason(for: error, verb: "open your conversation"))
            }
        }
    }

    /// Their conversation, made if there's none yet.
    private func conversation(with userID: UserID) async throws -> ChannelID {
        if let existing = model.directMessageChannel(with: userID) { return existing }
        let channel = try await rest.openDirectMessage(with: userID)
        model.channelIndex.upsert(channel)
        return channel.id
    }
}
