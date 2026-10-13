import Foundation
import WingcordCore

// MARK: - Fake Nitro, on the way out
//
// Vencord's plugin, as Alex asked for it (decision 9): what this account
// cannot send — another server's emoji or stickers without Nitro or the
// channel's permission, an animated emoji without Nitro — goes as a link to its
// picture, in the plugin's own format (`FakeNitroSend`). Off unless the
// reader turns it on, and applied to edits as the plugin applies it.

extension AppModel {

    /// The words and stickers to send, with Fake Nitro's links in place of
    /// whatever this account cannot use in this channel — and whether any link
    /// went in, which is the plugin's `hasBypass`.
    func applyingFakeNitro(
        _ content: String, stickerIDs: [UInt64], in channelID: ChannelID
    ) -> (content: String, stickerIDs: [UInt64], bypassed: Bool) {
        let settings = AppSettings.shared
        let home = channelIndex[channelID]?.guildID
        let original = content
        let originalStickers = stickerIDs
        var content = content
        var stickerIDs = stickerIDs

        if settings.sendsFakeEmoji {
            let usesExternal = canUseExternalEmoji(in: channelID)
            let usesAnimated = entitlements.has(.animatedEmoji)
            let homeEmoji = Set(home.flatMap { guildEmojis[$0] }?.compactMap(\.id) ?? [])
            content = FakeNitroSend.replacingEmoji(in: content) { emoji in
                guard let id = emoji.id else { return false }
                if emoji.isAnimated, !usesAnimated { return true }
                return !homeEmoji.contains(id) && !usesExternal
            }
        }

        if settings.sendsFakeStickers, !canUseExternalStickers(in: channelID) {
            let homeStickers = Set(home.flatMap { guildStickers[$0] }?.map(\.id) ?? [])
            for id in stickerIDs where !homeStickers.contains(id) {
                // Another server's sticker: as its link, when it has a picture.
                guard let sticker = guildStickers.values.lazy.flatMap({ $0 }).first(where: { $0.id == id }),
                      let link = FakeNitroSend.link(for: sticker)
                else { continue }
                content = FakeNitroSend.appending(link, to: content)
                stickerIDs.removeAll { $0 == id }
            }
        }
        return (content, stickerIDs, content != original || stickerIDs != originalStickers)
    }

    /// The plugin's APNG branch: an animated sticker this account cannot send
    /// here, which goes neither as a sticker nor as a link — see
    /// `trayAnimatedSticker`.
    func fakeNitroAnimatedSticker(in stickerIDs: [UInt64], channelID: ChannelID) -> StickerRef? {
        guard AppSettings.shared.sendsFakeStickers, !canUseExternalStickers(in: channelID) else { return nil }
        let home = channelIndex[channelID]?.guildID
        let homeStickers = Set(home.flatMap { guildStickers[$0] }?.map(\.id) ?? [])
        for id in stickerIDs where !homeStickers.contains(id) {
            if let sticker = guildStickers.values.lazy.flatMap({ $0 }).first(where: { $0.id == id }),
               sticker.format == .apng
            {
                return sticker
            }
        }
        return nil
    }

    /// The sticker, redrawn as `<id>.gif`, into the channel's tray — the
    /// plugin's `sendAnimatedSticker`, whose `promptToUpload` stages it rather
    /// than sending it. The words stay in the field; Return sends both.
    func trayAnimatedSticker(_ sticker: StickerRef, in channelID: ChannelID) {
        guard let url = CDN.sticker(id: sticker.id, format: sticker.format) else { return }
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let gif = await Task.detached(operation: { AnimatedStickerGIF.gif(fromAnimatedPNG: data) }).value
            else { return }
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("FakeNitroStickers", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let file = folder.appendingPathComponent("\(sticker.id).gif")
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try gif.write(to: file)
            } catch {
                return
            }
            stageAttachments([file], in: channelID)
        }
    }

    /// The stickers other Fake Nitro users' animated stickers stand for — the
    /// plugin uploads one as `<sticker id>.gif` — among the channel's loaded
    /// messages, for the ones the reader's servers know (the plugin's own test:
    /// its sticker store). Empty for nearly every channel, and cheap to be:
    /// only a GIF attachment is looked at twice.
    func fakeGIFStickers(in channelID: ChannelID) -> [UInt64: StickerRef] {
        guard let messages = messages(in: channelID)?.messages else { return [:] }
        var wanted: Set<UInt64> = []
        for message in messages {
            for attachment in message.attachments {
                if let id = FakeNitroLink.gifStickerID(in: attachment) { wanted.insert(id) }
            }
        }
        guard !wanted.isEmpty else { return [:] }
        var found: [UInt64: StickerRef] = [:]
        for stickers in guildStickers.values {
            for sticker in stickers where wanted.contains(sticker.id) { found[sticker.id] = sticker }
        }
        return found
    }

    /// The plugin's check before a send or an edit: links went in, and the
    /// channel will not embed them, so everybody would see links. A
    /// conversation embeds everything.
    func needsFakeNitroEmbedPrompt(bypassed: Bool, in channelID: ChannelID) -> Bool {
        guard bypassed, !AppSettings.shared.fakeNitroSkipsEmbedCheck,
              channelIndex[channelID]?.guildID != nil else { return false }
        return !permissionGate.permissions(in: channelID).contains(.embedLinks)
    }
}

/// Vencord's "Hold on!" before a Fake Nitro send or edit the channel will not
/// embed — and what Send Anyway does. (The other "Hold on!", for an animated
/// sticker where files are not allowed, is `AppModel.fakeNitroStickerRefused`.)
struct FakeNitroEmbedPrompt: Identifiable {
    let id = UUID()
    let proceed: @MainActor () -> Void
}
