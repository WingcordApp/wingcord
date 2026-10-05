import AppKit
import SwiftUI
import WingcordCore

// MARK: - "Streaming …", on somebody's profile
//
// Discord's live activity card (`64622`): a Go Live in a server, with its
// newest frame, the channel it is in and who is watching, and the way in.

/// Everything the card draws, resolved once.
struct ProfileStreamPresentation: Equatable, Sendable {
    var ownerID: UserID
    /// The stream's Go Live key, which names its preview.
    var key: String
    /// "Streaming {game}", or plain "Streaming" for a screen with no game.
    var gameName: String?
    var channelID: ChannelID
    var channelName: String
    var channelSymbol: String
    var guildID: GuildID
    var guildName: String
    var guildIconURL: URL?
    var guildMonogram: String
    var faces: [ProfileVoicePresentation.Face]
    var previewURL: URL?
    var isOwn: Bool
    var isWatching: Bool
    var isReaderHere: Bool
    /// Whether the reader may connect — Discord fetches no preview otherwise.
    var canConnect: Bool
    /// Why the reader cannot watch, in Discord's words (`711589`), or nil.
    var refusal: String?

    /// What the picture says under the pointer.
    var action: String {
        if isOwn { return "You\u{2019}re Streaming!" }
        if isWatching { return "Watching Stream" }
        return refusal ?? "Watch Stream"
    }

    var canWatch: Bool { !isOwn && refusal == nil }
}

extension AppModel {
    /// Somebody's Go Live, as their profile should draw it — Discord's
    /// `getStreamForUser` and the card's own guards: a stream in a server, on
    /// a channel the reader can see, and nothing for somebody offline or
    /// invisible or in another server than the one the profile was opened from.
    func profileStream(for userID: UserID, inGuild guildID: GuildID?) -> ProfileStreamPresentation? {
        let isOwn = userID == currentUserID
        let status = isOwn ? selfStatus : presences[userID]?.status ?? .offline
        guard status != .offline, status != .invisible else { return nil }
        guard let state = voiceStates[userID], let channelID = state.channelID,
              state.isStreaming || (isOwn && isScreenSharing),
              let channel = channelIndex[channelID],
              let streamGuildID = channel.guildID, let guild = guilds[streamGuildID],
              permissionGate.canView(channelID)
        else { return nil }
        if let guildID, guildID != streamGuildID { return nil }

        let key = GoLiveKey.make(guildID: streamGuildID, channelID: channelID, userID: userID)
        let isHere = connectedVoiceChannelID == channelID
        let canConnect = permissionGate.canJoinVoice(channelID)
        let refusal: String? = if !canConnect && !isHere {
            "No permission"
        } else if !isHere && isFull(channel) {
            "Channel is full"
        } else {
            nil
        }
        let game = presences[userID]?.activities?.list.first { $0.kind == .playing }?.name
        return ProfileStreamPresentation(
            ownerID: userID,
            key: key,
            gameName: game,
            channelID: channelID,
            channelName: displayName(of: channel),
            channelSymbol: channel.kind.symbolName,
            guildID: streamGuildID,
            guildName: guild.name,
            guildIconURL: guild.iconHash.flatMap { CDN.guildIcon(guildID: streamGuildID, hash: $0, side: 32) },
            guildMonogram: guild.monogram,
            faces: voiceStates(in: channelID).map { other in
                let user = users[other.userID]
                return ProfileVoicePresentation.Face(
                    id: other.userID,
                    name: voiceName(of: other.userID, inGuild: streamGuildID),
                    avatarURL: user.flatMap { avatarURL(for: $0, side: 32) },
                    monogram: user?.monogram ?? "?"
                )
            },
            // Discord asks for a preview only for somebody who may join.
            previewURL: canConnect || isHere ? streamPreviews[key] : nil,
            isOwn: isOwn,
            isWatching: watchedStreamUserID == userID,
            isReaderHere: isHere,
            canConnect: canConnect,
            refusal: refusal
        )
    }

    /// The picture's click: into the channel, and onto the stream — Discord's
    /// `selectVoiceChannel` then `watchStream` — and the card goes.
    func watchStream(from stream: ProfileStreamPresentation) {
        guard stream.canWatch else { return }
        profileRequest = nil
        if !stream.isReaderHere { joinVoice(stream.channelID) }
        selectChannel(stream.channelID)
        if !stream.isWatching { toggleWatchingStream(stream.ownerID) }
    }

    /// Join Voice under the card: into the channel without the stream.
    func joinVoice(from stream: ProfileStreamPresentation) {
        profileRequest = nil
        if !stream.isReaderHere { joinVoice(stream.channelID) }
        selectChannel(stream.channelID)
    }
}

/// Discord's live activity card.
///
/// ```
/// Streaming ROBLOX  LIVE                    ⋯
/// ┌──────────────────────────────────────┐
/// │              the preview             │
/// └──────────────────────────────────────┘
/// ──────────────────────────────────────────
/// [server] › 🔊 General VC           ●●● +3
/// [              Join Voice              ]
/// ```
struct ProfileStreamCard: View {
    var stream: ProfileStreamPresentation
    var form: ProfileVoiceCard.Form
    var ground: ProfileGround
    var platesItself = true
    var watch: () -> Void
    var join: () -> Void
    var openGuild: (GuildID) -> Void
    /// "View All Activity", in the popout only.
    var viewAllActivity: (() -> Void)?

    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHoveringPreview = false

    /// Discord's refresh is its store's; this one lives as long as the card.
    private static let refresh = Duration.seconds(60)

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            header
            if form == .sheet {
                HStack(alignment: .center, spacing: Spacing.snug) {
                    preview.frame(width: 100, height: 100)
                    VStack(alignment: .leading, spacing: Spacing.tight) {
                        Text(stream.channelName)
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundStyle(InkColor.primary)
                            .lineLimit(1)
                        faces
                        joinButton
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                preview
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                Divider()
                channelRow
                joinButton
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(platesItself ? Spacing.base : 0)
        .background {
            if platesItself { ProfilePanelPlate(ground: ground) }
        }
        .task(id: stream.key) {
            guard stream.canConnect || stream.isReaderHere else { return }
            // A loop rather than a timer, so it dies with the card.
            while !Task.isCancelled {
                model.requestStreamPreview(key: stream.key)
                try? await Task.sleep(for: Self.refresh)
            }
        }
    }

    // MARK: The parts

    private var header: some View {
        HStack(spacing: Spacing.tight) {
            Text(stream.gameName.map { "Streaming \($0)" } ?? "Streaming")
                .font(.system(.caption, weight: .medium))
                .foregroundStyle(InkColor.primary)
                .lineLimit(1)
            LiveChip()
            Spacer(minLength: 0)
            if let viewAllActivity {
                Menu {
                    Button("View All Activity", action: viewAllActivity)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(InkColor.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
                .accessibilityLabel(Text("More"))
            }
        }
    }

    /// The newest frame, or Discord's own picture until there is one — with
    /// what a click does written over it under the pointer.
    private var preview: some View {
        Button(action: watch) {
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.black.opacity(0.85))
                if let url = stream.previewURL {
                    RemoteImage(url: url, side: 320, bucket: .artwork) { Color.clear }
                        .aspectRatio(contentMode: .fit)
                } else if let art = StreamPlaceholderArt.image(dark: colorScheme == .dark) {
                    VStack(spacing: Spacing.tight) {
                        Image(nsImage: art)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxHeight: 48)
                        if form == .card {
                            Text(stream.canConnect || stream.isReaderHere
                                ? "Stream just started. Get in here!"
                                : "No permission")
                                .font(.system(.caption, weight: .medium))
                                .foregroundStyle(InkColor.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .padding(Spacing.base)
                }
                if form == .card, isHoveringPreview {
                    Text(stream.action)
                        .font(.system(.subheadline, weight: .medium))
                        .foregroundStyle(Color.white)
                        .padding(.vertical, 7)
                        .padding(.horizontal, 16)
                        .background(Color.black.opacity(0.6), in: .rect(cornerRadius: 4, style: .continuous))
                }
            }
            .clipShape(.rect(cornerRadius: 4, style: .continuous))
            .contentShape(.rect(cornerRadius: 4, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!stream.canWatch)
        .onHover { hovering in
            guard hovering != isHoveringPreview else { return }
            isHoveringPreview = hovering
        }
        .help(stream.action)
        .accessibilityLabel(Text(stream.action))
    }

    /// The server's mark, a chevron, the channel, and who is in it.
    private var channelRow: some View {
        HStack(spacing: Spacing.tight) {
            Button { openGuild(stream.guildID) } label: {
                AvatarView(url: stream.guildIconURL, monogram: stream.guildMonogram, side: 16)
                    .clipShape(.rect(cornerRadius: 4, style: .continuous))
            }
            .buttonStyle(.plain)
            .help(stream.guildName)
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(InkColor.tertiary)
            Button(action: join) {
                Label {
                    Text(stream.channelName).lineLimit(1)
                } icon: {
                    Image(symbol: stream.channelSymbol)
                }
                .labelStyle(.titleAndIcon)
                .font(.system(.caption))
                .foregroundStyle(InkColor.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!stream.canConnect)
            Spacer(minLength: Spacing.tight)
            faces
        }
    }

    /// Up to three faces, then how many more — Discord's `maxUsers: 3`.
    private var faces: some View {
        HStack(spacing: -4) {
            ForEach(stream.faces.prefix(3)) { face in
                AvatarView(url: face.avatarURL, monogram: face.monogram, side: 16)
                    .help(face.name)
            }
            if stream.faces.count > 3 {
                Text("+\(min(stream.faces.count - 3, 99))")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(InkColor.secondary)
                    .padding(.horizontal, 4)
                    .frame(height: 16)
                    .background(ground.panelFill, in: .capsule)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text(stream.faces.map(\.name).joined(separator: ", ")))
    }

    /// Join Voice, under somebody else's stream — Discord draws none on the
    /// streamer's own card.
    @ViewBuilder
    private var joinButton: some View {
        if !stream.isOwn, stream.canConnect {
            Button(action: join) {
                Text(form == .sheet
                    ? (stream.isReaderHere ? "Open" : "Join")
                    : (stream.isReaderHere ? "Open Voice" : "Join Voice"))
                    .font(.system(.subheadline, weight: .medium))
                    .foregroundStyle(InkColor.primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .interactiveChromeOverMedia()
        }
    }
}

/// Discord's picture for a stream with no frame yet, in the room's tone.
private enum StreamPlaceholderArt {
    @MainActor private static var cache: [Bool: NSImage] = [:]

    @MainActor static func image(dark: Bool) -> NSImage? {
        if let hit = cache[dark] { return hit }
        guard let url = Bundle.module.url(
            forResource: dark ? "stream-placeholder-dark" : "stream-placeholder-light",
            withExtension: "svg",
            subdirectory: "Art"
        ), let image = NSImage(contentsOf: url) else { return nil }
        cache[dark] = image
        return image
    }
}
