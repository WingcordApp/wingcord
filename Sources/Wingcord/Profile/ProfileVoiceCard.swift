import SwiftUI
import WingcordCore

// MARK: - "In voice", "In a call", "In a stage", on somebody's profile
//
// Discord's voice activity card (`986712`), built from what the client already
// holds — the person's voice state off the gateway, the channel and server it
// names, everybody else in it, and the channel's own status. No route answers
// it: `in voice card22_1.har` is the whole capture of opening a profile on
// somebody in a call, and it holds one profile fetch and nothing else.

/// Everything the card draws, resolved once.
struct ProfileVoicePresentation: Equatable, Sendable {
    /// Which of Discord's three cards this is.
    enum Place: Equatable, Sendable {
        case voice
        case stage
        /// A call in a direct message or a group.
        case call
    }

    struct Face: Equatable, Sendable, Identifiable {
        var id: UserID
        var name: String
        var avatarURL: URL?
        var monogram: String
    }

    var channelID: ChannelID
    var place: Place
    var channelName: String
    var channelSymbol: String
    /// The server's id and name, for "in {server}". Nil for a call.
    var guildID: GuildID?
    var guildName: String?
    /// Everybody in the channel, in the channel's own order.
    var faces: [Face]
    /// What the channel says it is for — Discord's voice-channel status.
    var status: [VoiceChannelStatus.Run]
    /// Whether the reader may set that status from here: in the channel, and
    /// holding `SET_VOICE_CHANNEL_STATUS`. See `ProfileVoiceCard.statusRow`.
    var canSetStatus: Bool
    /// Whether the reader is in that call, which turns Join into Open.
    var isReaderHere: Bool
    /// Whether the reader may connect. **No button where they may not** — a
    /// Join the server will refuse is the inert control §5.5 forbids.
    var canConnect: Bool
    /// The reader's own card, which says who else can see it.
    var isOwn: Bool
}

extension AppModel {
    /// The call somebody is in, as their profile should draw it — Discord's
    /// `useVoiceChannel` and `getActivityCards`, rule for rule.
    ///
    /// **Nil where Discord draws nothing:** for somebody offline or invisible;
    /// for a call in another server than the one the profile was opened from;
    /// and for a channel the reader cannot see — reporting it would be this
    /// client telling somebody where a person is when Discord deliberately does
    /// not. A call in a direct message or a group shows wherever the reader is
    /// in that conversation too, which is what `channelIndex` holding it means.
    ///
    /// - Parameter guildID: the server the profile was opened in, or nil.
    func profileVoice(for userID: UserID, inGuild guildID: GuildID?) -> ProfileVoicePresentation? {
        let isOwn = userID == currentUserID
        let status = isOwn ? selfStatus : presences[userID]?.status ?? .offline
        guard status != .offline, status != .invisible else { return nil }
        guard let state = voiceStates[userID], let channelID = state.channelID,
              let channel = channelIndex[channelID]
        else { return nil }

        let place: ProfileVoicePresentation.Place
        switch channel.kind {
        case .directMessage, .groupDirectMessage:
            // Discord's `getDiscoverableVoiceState(guildId, …)` names only a
            // state in that server, and a call is in none.
            guard guildID == nil else { return nil }
            place = .call
        case .stage, .voice:
            guard permissionGate.canView(channelID) else { return nil }
            if let guildID, channel.guildID != guildID { return nil }
            place = channel.kind == .stage ? .stage : .voice
        default:
            return nil
        }

        let channelGuildID = channel.guildID
        let faces = voiceStates(in: channelID).map { other in
            let user = users[other.userID]
            return ProfileVoicePresentation.Face(
                id: other.userID,
                name: voiceName(of: other.userID, inGuild: channelGuildID),
                avatarURL: user.flatMap { avatarURL(for: $0, side: 80) },
                monogram: user?.monogram ?? "?"
            )
        }
        let isReaderHere = connectedVoiceChannelID == channelID
        return ProfileVoicePresentation(
            channelID: channelID,
            place: place,
            channelName: displayName(of: channel),
            channelSymbol: place == .call ? "phone.fill" : channel.kind.symbolName,
            guildID: channelGuildID,
            guildName: channelGuildID.flatMap { guilds[$0]?.name },
            faces: faces,
            status: voiceChannelInfo[channelID]?.status.map(VoiceChannelStatus.runs) ?? [],
            canSetStatus: place == .voice && isReaderHere
                && permissionGate.permissions(in: channelID).contains(.setVoiceChannelStatus),
            isReaderHere: isReaderHere,
            canConnect: place == .call || permissionGate.canJoinVoice(channelID),
            isOwn: isOwn
        )
    }

    /// Join, or Open — Discord's `selectVoiceChannel` then `transitionTo`, for
    /// a channel the reader is already in only the second — and the card goes,
    /// as Discord's `onClose` takes it.
    func openVoice(from voice: ProfileVoicePresentation) {
        profileRequest = nil
        if !voice.isReaderHere {
            switch voice.place {
            case .call: joinCall(in: voice.channelID)
            case .voice, .stage: joinVoice(voice.channelID)
            }
        }
        selectChannel(voice.channelID)
    }
}

/// Discord's voice activity card.
///
/// ```
/// In voice ⓘ                               ⋯
/// ┌────────┐ 🔊 General VC
/// │ ●   +2 │ in Spooky Minecraft Server
/// │ ●    ● │ Status for the channel ✎
/// └────────┘
/// [             Join Voice              ]
/// ```
struct ProfileVoiceCard: View {
    enum Form {
        /// The popout and the direct-message column — Discord's popout card.
        case card
        /// The full profile's Activity tab — Discord's `MODAL_V2`: a larger
        /// cluster, and the button's shorter words.
        case sheet
    }

    var voice: ProfileVoicePresentation
    var form: Form
    var ground: ProfileGround
    /// Whether the card draws its own plate — false inside the full profile's
    /// slab. See `CurrentActivityCard.platesItself`.
    var platesItself = true
    var open: () -> Void
    /// Opens the server the channel is in.
    var openGuild: (GuildID) -> Void
    /// "Set a channel status", for a reader who may.
    var setStatus: () -> Void
    /// "View All Activity" — the popout's only menu item. Nil draws no menu,
    /// which is the full profile, where the reader already is.
    var viewAllActivity: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            header
            HStack(alignment: .center, spacing: form == .sheet ? Spacing.snug : Spacing.base) {
                VoiceAvatarCluster(faces: voice.faces, form: form, ground: ground)
                details
            }
            if voice.canConnect {
                Button(action: open) {
                    Text(buttonTitle)
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(platesItself ? Spacing.base : 0)
        .background {
            if platesItself { ProfilePanelPlate(ground: ground) }
        }
    }

    // MARK: The parts

    /// "In voice", and on the reader's own card who can see it.
    private var header: some View {
        HStack(spacing: Spacing.tight) {
            Text(title)
                .font(.system(.caption, weight: .medium))
                .foregroundStyle(InkColor.primary)
                .lineLimit(1)
            if voice.isOwn {
                Image(systemName: "info.circle")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(InkColor.secondary)
                    .help(voice.place == .call
                        ? "Only visible to people with access to this chat"
                        : "Only visible to people with access to this channel")
            }
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

    /// The channel, its server, and its status.
    private var details: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            Button(action: open) {
                Label {
                    Text(voice.channelName)
                        .font(.system(.subheadline, weight: .semibold))
                        .lineLimit(1)
                } icon: {
                    Image(symbol: voice.channelSymbol)
                        .font(.system(size: 11, weight: .semibold))
                }
                .labelStyle(.titleAndIcon)
                .foregroundStyle(InkColor.primary)
            }
            .buttonStyle(UnderlinesOnHover())
            .disabled(!voice.canConnect)
            if let guildID = voice.guildID, let guildName = voice.guildName {
                Button { openGuild(guildID) } label: {
                    Text("in \(guildName)")
                        .font(.system(.caption))
                        .foregroundStyle(InkColor.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .buttonStyle(UnderlinesOnHover())
            }
            statusRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Discord's `Y`: the status as written — with its custom emoji, which is
    /// what it very often carries — or, for a reader in the channel who may
    /// set one, the status or "Set a channel status" with Discord's pencil.
    @ViewBuilder
    private var statusRow: some View {
        if voice.canSetStatus {
            Button(action: setStatus) {
                HStack(spacing: Spacing.tight) {
                    if voice.status.isEmpty {
                        Text("Set a channel status")
                            .font(.system(.caption))
                            .foregroundStyle(InkColor.secondary)
                    } else {
                        VoiceStatusLine(runs: voice.status)
                    }
                    Image(systemName: "pencil")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(InkColor.secondary)
                        .accessibilityLabel(Text("Edit"))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        } else if !voice.status.isEmpty {
            VoiceStatusLine(runs: voice.status)
        }
    }

    private var title: String {
        switch voice.place {
        case .voice: "In voice"
        case .stage: "In a stage"
        case .call: "In a call"
        }
    }

    /// Discord's labels (`70963`): Join or Open, and on the full profile the
    /// bare verb.
    private var buttonTitle: String {
        if form == .sheet { return voice.isReaderHere ? "Open" : "Join" }
        switch (voice.place, voice.isReaderHere) {
        case (.voice, false): return "Join Voice"
        case (.voice, true): return "Open Voice"
        case (.stage, false): return "Join Stage"
        case (.stage, true): return "Open Stage"
        case (.call, false): return "Join Call"
        case (.call, true): return "Open Call"
        }
    }
}

/// A link-like button: plain text, underlined while the pointer is on it —
/// Discord's `clickableText:hover`.
private struct UnderlinesOnHover: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .underline(isHovering)
            .onHover { isHovering = $0 }
    }
}

/// Everybody in the call, as Discord tiles them (`b` in `986712`): up to four
/// faces at its own sizes and places, and past four the second slot — the
/// fourth, once the rest number ten — becomes "+N".
struct VoiceAvatarCluster: View {
    var faces: [ProfileVoicePresentation.Face]
    var form: ProfileVoiceCard.Form
    var ground: ProfileGround

    /// One face's box in the tile: top, left, side.
    private typealias Slot = (top: CGFloat, left: CGFloat, side: CGFloat)

    /// Discord's `D`, for a 60-point tile.
    private static let card: [[Slot]] = [
        [(15, 15, 28)],
        [(7, 7, 20), (25, 25, 26)],
        [(5, 10, 18), (15, 31, 22), (29, 5, 24)],
        [(5, 5, 22), (7, 33, 18), (33, 7, 18), (31, 31, 22)],
    ]
    /// Discord's `V`, for the full profile's 100-point tile.
    private static let sheet: [[Slot]] = [
        [(23, 23, 52)],
        [(13, 13, 32), (41, 41, 44)],
        [(9, 14, 31), (27, 53, 34), (52, 11, 36)],
        [(10, 10, 36), (10, 57, 31), (57, 10, 31), (52, 52, 36)],
    ]

    var body: some View {
        let side: CGFloat = form == .sheet ? 100 : 60
        let table = form == .sheet ? Self.sheet : Self.card
        let slots = table[max(0, min(faces.count, 4) - 1)]
        // Past four, one slot counts the rest — the second, or the fourth
        // once the overflow reaches ten.
        let overflow = faces.count > 4 ? faces.count - 3 : 0
        let countSlot = overflow >= 10 ? 3 : 1
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(ground.panelFill)
                .overlay {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(ground.panelEdge ?? Color.white.opacity(0.08), lineWidth: 1)
                }
            ForEach(Array(slots.enumerated()), id: \.offset) { index, slot in
                Group {
                    if overflow > 0, index == countSlot {
                        Text(overflow > 99 ? ">99" : "+\(overflow)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(InkColor.primary)
                            .minimumScaleFactor(0.6)
                            .frame(width: slot.side, height: slot.side)
                            .background(outline, in: .circle)
                    } else if faces.indices.contains(index) {
                        AvatarView(url: faces[index].avatarURL, monogram: faces[index].monogram, side: slot.side)
                            .overlay {
                                Circle().strokeBorder(outline, lineWidth: form == .sheet ? 3 : 2)
                            }
                            .help(faces[index].name)
                    }
                }
                .shadow(color: .black.opacity(0.24), radius: 4, y: 2)
                .offset(x: slot.left, y: slot.top)
            }
        }
        .frame(width: side, height: side)
        .accessibilityElement()
        .accessibilityLabel(Text(faces.map(\.name).joined(separator: ", ")))
    }

    /// The ring round each face and the "+N" disc: Discord's
    /// `--background-surface-highest`, or on a themed profile white at 24% in
    /// a dark one and 72% in a light one.
    private var outline: Color {
        switch ground {
        case .themed: ground.wantsDarkInk ? Color.white.opacity(0.72) : Color.white.opacity(0.24)
        case .neutral: Palette.surfaceRaised
        }
    }
}
