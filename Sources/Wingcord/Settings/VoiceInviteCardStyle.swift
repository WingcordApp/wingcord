import Foundation

/// Which card a voice invite gets — Settings › Experiments.
enum VoiceInviteCardStyle: String, CaseIterable, Hashable, Sendable {
    /// Discord's experiment `2026-05_voice_channel_list_invite_embed`, as it
    /// puts the invite's server: the channel row in treatment, the card in
    /// control.
    case asDiscordDecides
    /// The channel row everywhere.
    case channelRow
    /// Discord's shipped card everywhere.
    case card

    var title: String {
        switch self {
        case .asDiscordDecides: "As Discord decides"
        case .channelRow: "Channel row"
        case .card: "Card"
        }
    }

    var detail: String {
        switch self {
        case .asDiscordDecides: "Follows Discord's experiment for each server."
        case .channelRow: "The channel as the sidebar shows it, with who is inside."
        case .card: "Discord's card: who invited you, their faces, Join Voice."
        }
    }
}
