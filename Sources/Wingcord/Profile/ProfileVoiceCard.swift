import SwiftUI
import WingcordCore

// MARK: - "In voice", on somebody's profile
//
// **No route answers this.** `in voice card22_1.har` is the whole capture of
// opening a profile on somebody who is in a call, and it holds one profile fetch
// and nothing else — the card is built entirely from what the client already
// has: the person's voice state off the gateway, the channel and guild it names,
// and that channel's own status. Which is also why it can appear the instant
// somebody joins rather than a round trip later.

/// Everything the card draws, resolved once.
struct ProfileVoicePresentation: Equatable, Sendable {
    var channelID: ChannelID
    var channelName: String
    var guildName: String
    var guildIconURL: URL?
    var guildMonogram: String
    /// The person's own face, which the tile sits over the guild's icon.
    var avatarURL: URL?
    var avatarMonogram: String
    /// What the channel says it is for — Discord's voice-channel status.
    var status: [VoiceChannelStatus.Run]
    /// Whether the reader may actually join. **A Join the server will refuse is
    /// the inert control §5.5 forbids**, so a channel they cannot connect to
    /// draws the card without the button rather than with a dead one.
    var canJoin: Bool
    /// Whether the reader is already in that call.
    var isReaderHere: Bool
}

extension AppModel {

    /// The call somebody is in, as their profile should draw it.
    ///
    /// **Nil for the reader themselves and for a call they cannot see.** A
    /// profile is opened from a server, and a voice channel the reader has no
    /// `VIEW_CHANNEL` on is one Discord does not name either — reporting it
    /// would be this client telling somebody where a person is when Discord
    /// deliberately does not.
    func profileVoice(for userID: UserID) -> ProfileVoicePresentation? {
        guard userID != currentUserID else { return nil }
        guard let state = voiceStates[userID], let channelID = state.channelID else {
            return nil
        }
        guard permissionGate.canView(channelID) else { return nil }
        guard let channel = channelIndex[channelID] else { return nil }
        let guildID = channel.guildID ?? state.guildID
        let guild = guildID.flatMap { guilds[$0] }
        let info = voiceChannelInfo[channelID]
        let user = users[userID]
        return ProfileVoicePresentation(
            channelID: channelID,
            channelName: channel.name,
            guildName: guild?.name ?? "",
            guildIconURL: guildID.flatMap { id in
                guild?.iconHash.flatMap { CDN.guildIcon(guildID: id, hash: $0, side: 40) }
            },
            guildMonogram: guild?.monogram ?? "?",
            avatarURL: user.flatMap { avatarURL(for: $0, side: 32) },
            avatarMonogram: user?.monogram ?? "?",
            status: info?.status.map(VoiceChannelStatus.runs) ?? [],
            canJoin: permissionGate.canJoinVoice(channelID),
            isReaderHere: connectedVoiceChannelID == channelID
        )
    }
}

/// The "In voice" panel on a profile.
///
/// **No overflow menu.** Discord draws a `…` in this header and every item
/// behind it is something this client has no route for yet; a control that opens
/// an empty menu is the one §5.5 forbids. It comes back with something to put
/// in it.
struct ProfileVoiceCard: View {
    var voice: ProfileVoicePresentation
    var width: CGFloat
    var join: (ChannelID) -> Void

    private static let thumbnailSide: CGFloat = 64

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            Text("In voice")
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(InkColor.primary)

            HStack(alignment: .top, spacing: Spacing.snug) {
                thumbnail
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: Spacing.tight) {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(InkColor.primary)
                        Text(voice.channelName)
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundStyle(InkColor.primary)
                            .lineLimit(1)
                    }
                    if !voice.guildName.isEmpty {
                        Text("in \(voice.guildName)")
                            .font(.system(.caption))
                            .foregroundStyle(InkColor.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    // The channel's own status, drawn with its emoji rather
                    // than as a plain string — it is written by somebody and
                    // very often carries custom emoji.
                    if !voice.status.isEmpty {
                        VoiceStatusLine(runs: voice.status)
                            .padding(.top, 1)
                    }
                }
                Spacer(minLength: 0)
            }

            if voice.canJoin {
                Button { join(voice.channelID) } label: {
                    Text(voice.isReaderHere ? "You're Here" : "Join Voice")
                        .font(.system(.subheadline, weight: .medium))
                        .foregroundStyle(InkColor.primary)
                        .frame(maxWidth: .infinity)
                        .frame(height: Metrics.control + 6)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(voice.isReaderHere)
                .background(Palette.hoverFill, in: .rect(cornerRadius: Radius.row))
            }
        }
        .padding(Spacing.snug)
        .frame(width: width, alignment: .leading)
        .background(Palette.hoverFill, in: .rect(cornerRadius: Radius.chip))
    }

    /// The guild's icon with the person's face tucked into its corner — one
    /// tile that says both which server and who, which is what the reference
    /// draws.
    private var thumbnail: some View {
        AvatarView(
            url: voice.guildIconURL,
            monogram: voice.guildMonogram,
            side: Self.thumbnailSide
        )
        .clipShape(.rect(cornerRadius: Radius.row, style: .continuous))
        .overlay(alignment: .bottomTrailing) {
            AvatarView(url: voice.avatarURL, monogram: voice.avatarMonogram, side: 30)
                .padding(3)
        }
        .frame(width: Self.thumbnailSide, height: Self.thumbnailSide)
        .accessibilityHidden(true)
    }
}
