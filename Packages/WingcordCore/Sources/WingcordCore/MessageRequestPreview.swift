import Foundation

extension Message {
    /// What a message request draws of this message before it is accepted:
    /// its words and its reply line — nothing that loads — and how many pieces
    /// of media it held.
    ///
    /// **Discord's restricted preview** (`d8`'s `renderRestrictedHiddenMedia`):
    /// attachments and embeds are counted into "Image attachment" placeholders,
    /// a forward's own are counted in their place, and every other accessory —
    /// a sticker, a poll, controls, reactions — is not drawn at all. "Accept
    /// the request to send a message, view attachments, and use links."
    public var restrictedPreview: (message: Message, hiddenMedia: Int) {
        guard let payload else { return (self, 0) }
        let forwarded = payload.forwarded.map { $0.attachments.count + $0.embeds.count } ?? 0
        var restricted = self
        restricted.payload = MessagePayload(
            mentionedUserIDs: payload.mentionedUserIDs,
            mentionedRoleIDs: payload.mentionedRoleIDs,
            mentionsEveryone: payload.mentionsEveryone,
            reference: payload.reference,
            webhookID: payload.webhookID,
            nonce: payload.nonce,
            interaction: payload.interaction,
            applicationID: payload.applicationID
        )
        return (restricted, payload.attachments.count + payload.embeds.count + forwarded)
    }
}
