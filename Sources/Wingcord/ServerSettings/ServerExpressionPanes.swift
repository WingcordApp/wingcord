import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WingcordCore

// MARK: - The three expression pages
//
// They look like one page three times and they are not: **each uploads through a
// different encoding**, and none of the three is guessable from the others.
//
//   - Emoji is JSON with a `data:image/png;base64,…` URI.
//   - Soundboard is JSON with a `data:audio/ogg;base64,…` URI and a float volume.
//   - Stickers are `multipart/form-data` — the only multipart request this
//     client makes anywhere.
//
// The panes hide that difference; `DiscordREST+ServerSettings` states it. What
// they share is the shape: a slot meter, an upload control, and a table.

// MARK: - Emoji

struct EmojiPane: View {
    let store: ServerSettingsStore
    let model: AppModel

    @State private var renaming: EmojiID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LoadableContent(store.emoji) { emoji in
                let tier = store.settings.value?.premiumTier ?? 0
                let statics = emoji.filter { !$0.isAnimated }
                let animated = emoji.filter(\.isAnimated)

                SettingsGroup {
                    SettingsCard {
                        SlotMeter(
                            used: statics.count,
                            total: ExpressionSlots.emoji(premiumTier: tier),
                            noun: "emoji slots"
                        )
                        CardDivider()
                        SlotMeter(
                            used: animated.count,
                            total: ExpressionSlots.emoji(premiumTier: tier),
                            noun: "animated slots"
                        )
                        CardDivider()
                        SettingsActionRow(
                            "Upload Emoji",
                            help: "File type: JPEG, PNG, GIF, WEBP, AVIF",
                            actionTitle: "Upload Emoji",
                            action: upload
                        )
                    }
                }

                table("Emoji", entries: statics)
                table("Animated", entries: animated)
            }
        }
    }

    @ViewBuilder
    private func table(_ title: String, entries: [GuildEmoji]) -> some View {
        if !entries.isEmpty {
            SettingsGroup("\(title) — \(entries.count)") {
                SettingsCard {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { CardDivider() }
                        row(item)
                    }
                }
            }
        }
    }

    private func row(_ emoji: GuildEmoji) -> some View {
        ObjectRow(
            title: emoji.name,
            subtitle: subtitle(emoji),
            badge: emoji.shortcode
        ) {
            RemoteImage(
                url: CDN.emoji(id: emoji.id, animated: emoji.isAnimated, side: 28),
                side: 28
            ) {
                SettingsSurface.controlTrough
            }
            .frame(width: 28, height: 28)
            .clipShape(.rect(cornerRadius: 6, style: .continuous))
            // A lost-boost emoji is still listed and cannot be typed, so the
            // row says so by being dimmed rather than by being hidden.
            .opacity(emoji.isAvailable ? 1 : 0.4)
        } trailing: {
            // A managed emoji belongs to an integration and Discord refuses both
            // routes on it. §5.5 — no controls rather than controls that 403.
            if !emoji.isManaged {
                HStack(spacing: 2) {
                    RowIconButton(symbolName: "pencil", label: "Rename \(emoji.name)") {
                        renaming = emoji.id
                    }
                    RowIconButton(
                        symbolName: "trash",
                        label: "Delete \(emoji.name)",
                        role: .destructive
                    ) {
                        Task { await store.deleteEmoji(emoji.id) }
                    }
                }
            }
        }
        .modal(isPresented: Binding(
            get: { renaming == emoji.id },
            set: { if !$0 { renaming = nil } }
        )) {
            RenameSheet(title: "Edit Emoji", name: emoji.name) { name in
                Task { await store.renameEmoji(emoji.id, to: name) }
            }
        }
    }

    private func subtitle(_ emoji: GuildEmoji) -> String? {
        if emoji.isManaged { return "Managed by an integration" }
        if !emoji.isAvailable { return "Unavailable — this server has lost the boosts for it" }
        guard let uploader = emoji.uploader else { return nil }
        return model.users[uploader].map { "Added by \($0.preferredName)" }
    }

    /// Discord's uploader takes several files at once and adds them one after
    /// another; so does this. Each still is shrunk to fit the route's 256 KB.
    private func upload() {
        Task {
            let files = await ExpressionUpload.pickImages(
                allowsMultiple: true,
                maximumBytes: ExpressionSlots.emojiByteLimit
            )
            for file in files {
                await store.createEmoji(name: file.suggestedName, image: file.image)
            }
        }
    }
}

// MARK: - Stickers

struct StickersPane: View {
    let store: ServerSettingsStore
    let model: AppModel

    @State private var isUploading = false
    @State private var editing: GuildSticker?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LoadableContent(store.stickers) { stickers in
                SettingsGroup {
                    SettingsCard {
                        SlotMeter(
                            used: stickers.count,
                            total: ExpressionSlots.stickers(
                                premiumTier: store.settings.value?.premiumTier ?? 0
                            ),
                            noun: "sticker slots"
                        )
                        CardDivider()
                        SettingsActionRow(
                            "Upload Sticker",
                            actionTitle: "Upload Sticker"
                        ) {
                            isUploading = true
                        }
                    }
                }

                if stickers.isEmpty {
                    EmptyRow(
                        message: "Upload custom stickers for everyone to use",
                        symbolName: "seal"
                    )
                } else {
                    SettingsGroup("Stickers — \(stickers.count)") {
                        SettingsCard {
                            ForEach(Array(stickers.enumerated()), id: \.element.id) { index, sticker in
                                if index > 0 { CardDivider() }
                                row(sticker)
                            }
                        }
                    }
                }
            }
        }
        .modal(isPresented: $isUploading) {
            StickerSheet(existing: nil) { draft in
                guard let file = draft.file else { return }
                Task {
                    await store.createSticker(
                        name: draft.name,
                        relatedEmoji: draft.relatedEmoji,
                        description: draft.description.isEmpty ? nil : draft.description,
                        file: file.bytes,
                        filename: file.filename,
                        contentType: file.contentType
                    )
                }
            }
        }
    }

    private func row(_ sticker: GuildSticker) -> some View {
        ObjectRow(
            title: sticker.name,
            subtitle: subtitle(sticker),
            badge: sticker.relatedEmoji
        ) {
            RemoteImage(url: sticker.artworkURL, side: 32) {
                SettingsSurface.controlTrough
            }
            .frame(width: 32, height: 32)
            .clipShape(.rect(cornerRadius: 6, style: .continuous))
        } trailing: {
            HStack(spacing: 2) {
                RowIconButton(symbolName: "pencil", label: "Edit \(sticker.name)") {
                    editing = sticker
                }
                RowIconButton(
                    symbolName: "trash",
                    label: "Delete \(sticker.name)",
                    role: .destructive
                ) {
                    Task { await store.deleteSticker(sticker.id) }
                }
            }
        }
        .modal(isPresented: Binding(
            get: { editing?.id == sticker.id },
            set: { if !$0 { editing = nil } }
        )) {
            StickerSheet(existing: sticker) { draft in
                Task {
                    await store.saveSticker(
                        sticker.id,
                        name: draft.name,
                        relatedEmoji: draft.relatedEmoji,
                        description: draft.description.isEmpty ? nil : draft.description
                    )
                }
            }
        }
    }

    private func subtitle(_ sticker: GuildSticker) -> String? {
        if let description = sticker.description { return description }
        guard let uploader = sticker.uploader else { return nil }
        return model.users[uploader].map { "Added by \($0.preferredName)" }
    }
}

// MARK: - Soundboard

struct SoundboardPane: View {
    let store: ServerSettingsStore
    let model: AppModel

    @State private var isUploading = false
    @State private var editing: SoundboardSound?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LoadableContent(store.sounds) { sounds in
                SettingsGroup {
                    SettingsCard {
                        SlotMeter(
                            used: sounds.count,
                            total: ExpressionSlots.soundboard(
                                premiumTier: store.settings.value?.premiumTier ?? 0
                            ),
                            noun: "sound slots"
                        )
                        CardDivider()
                        SettingsActionRow(
                            "Upload Sound",
                            actionTitle: "Upload Sound"
                        ) {
                            isUploading = true
                        }
                    }
                }

                if sounds.isEmpty {
                    EmptyRow(message: "No Sounds — Get the party started by uploading a sound", symbolName: "speaker.wave.2")
                } else {
                    SettingsGroup("Sounds — \(sounds.count)") {
                        SettingsCard {
                            ForEach(Array(sounds.enumerated()), id: \.element.id) { index, sound in
                                if index > 0 { CardDivider() }
                                row(sound)
                            }
                        }
                    }
                }
            }
        }
        .modal(isPresented: $isUploading) {
            SoundSheet(existing: nil, guildID: store.guildID) { draft in
                guard let sound = draft.sound else { return }
                Task {
                    await store.createSound(
                        name: draft.name,
                        sound: sound,
                        volume: draft.volume,
                        emojiName: draft.emoji?.isCustom == true ? nil : draft.emoji?.name,
                        emojiID: draft.emoji?.id?.rawValue
                    )
                }
            }
        }
    }

    private func row(_ sound: SoundboardSound) -> some View {
        ObjectRow(
            title: sound.name,
            subtitle: store.soundUploaders[sound.id]
                .flatMap { model.users[$0] }
                .map { "Added by \($0.preferredName)" },
            badge: "\(Int(sound.volume * 100))%"
        ) {
            Text(sound.emojiName ?? "🔊")
                .font(.system(size: 16))
                .frame(width: 28, height: 28)
                .background(SettingsSurface.controlTrough, in: .circle)
        } trailing: {
            HStack(spacing: 2) {
                RowIconButton(symbolName: "pencil", label: "Edit \(sound.name)") {
                    editing = sound
                }
                RowIconButton(
                    symbolName: "trash",
                    label: "Delete \(sound.name)",
                    role: .destructive
                ) {
                    Task { await store.deleteSound(sound.id) }
                }
            }
        }
        .modal(isPresented: Binding(
            get: { editing?.id == sound.id },
            set: { if !$0 { editing = nil } }
        )) {
            SoundSheet(existing: sound, guildID: store.guildID) { draft in
                Task {
                    await store.saveSound(
                        sound.id,
                        name: draft.name,
                        volume: draft.volume,
                        emojiName: draft.emoji?.isCustom == true ? nil : draft.emoji?.name,
                        emojiID: draft.emoji?.id?.rawValue
                    )
                }
            }
        }
    }
}

// MARK: - Picking a file
//
// Shared by the three pages, so the file panel's allowed types and the
// name-from-filename rule live in one place.

enum ExpressionUpload {
    struct PickedImage {
        var image: ImageData
        /// Discord requires a name and the file already has one. Sanitised to
        /// what the route accepts — letters, digits and underscores — because a
        /// file called "my emoji (1).png" is a 400 that names the wrong field.
        var suggestedName: String
    }

    struct PickedFile {
        var bytes: Data
        var filename: String
        var contentType: String
    }

    /// The still formats Discord's own uploader takes, plus GIF where an
    /// animation is allowed.
    static func imageTypes(allowsAnimated: Bool) -> [UTType] {
        var types: [UTType] = [.png, .jpeg, .webP]
        if let avif = UTType(filenameExtension: "avif") { types.append(avif) }
        if allowsAnimated { types.append(.gif) }
        return types
    }

    /// Chooses images and prepares them for a JSON image route.
    ///
    /// **Every still goes up as PNG, re-encoded rather than relabelled.** This
    /// used to send a JPEG's bytes under `image/png`, which the route answers
    /// with a refusal that names the field rather than the encoding. Discord's
    /// own uploader re-encodes when it crops, and so does this — off the main
    /// actor, because a decode of a large photograph is the wrong thing to do
    /// between a click and the next frame.
    ///
    /// `maximumBytes` shrinks a still until it fits (an emoji's 256 KB); a GIF
    /// keeps its frames and the route judges its size.
    static func pickImages(
        allowsMultiple: Bool = false,
        allowsAnimated: Bool = true,
        maximumBytes: Int? = nil
    ) async -> [PickedImage] {
        let urls = panel(types: imageTypes(allowsAnimated: allowsAnimated), allowsMultiple: allowsMultiple)
        guard !urls.isEmpty else { return [] }
        return await Task.detached(priority: .userInitiated) {
            urls.compactMap { prepared($0, maximumBytes: maximumBytes) }
        }.value
    }

    /// A file dropped on a well, prepared as a picked one is — or nil when it
    /// is not one of the types the panel would have offered.
    static func image(at url: URL, allowsAnimated: Bool) async -> PickedImage? {
        guard let type = UTType(filenameExtension: url.pathExtension),
              imageTypes(allowsAnimated: allowsAnimated).contains(where: { type.conforms(to: $0) })
        else { return nil }
        return await Task.detached(priority: .userInitiated) { prepared(url, maximumBytes: nil) }.value
    }

    nonisolated private static func prepared(_ url: URL, maximumBytes: Int?) -> PickedImage? {
        guard let bytes = try? Data(contentsOf: url),
              let image = UploadImageEncoder.prepared(
                  bytes,
                  isGIF: url.pathExtension.lowercased() == "gif",
                  maximumBytes: maximumBytes
              )
        else { return nil }
        return PickedImage(
            image: image,
            suggestedName: sanitised(url.deletingPathExtension().lastPathComponent)
        )
    }

    static func pickFile(types: [UTType]) -> PickedFile? {
        guard let url = panel(types: types, allowsMultiple: false).first,
              let bytes = try? Data(contentsOf: url)
        else { return nil }
        return PickedFile(
            bytes: bytes,
            filename: url.lastPathComponent,
            contentType: contentType(for: url)
        )
    }

    nonisolated static func sanitised(_ name: String) -> String {
        let kept = name.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == "_"
        }
        let result = String(String.UnicodeScalarView(kept)).lowercased()
        // Discord's minimum is two characters, and an emoji made entirely of
        // punctuation would otherwise arrive as an empty name.
        return result.count >= 2 ? String(result.prefix(32)) : "emoji"
    }

    private static func panel(types: [UTType], allowsMultiple: Bool) -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = allowsMultiple
        panel.canChooseDirectories = false
        panel.allowedContentTypes = types
        guard panel.runModal() == .OK else { return [] }
        return panel.urls
    }

    private static func contentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "gif": "image/gif"
        case "jpg", "jpeg": "image/jpeg"
        case "json": "application/json"
        default: "image/png"
        }
    }
}
