import AppKit
import SwiftUI
import WingcordCore

/// A crosspost's publisher, raised from its author in the transcript — the
/// server that published it, not a person.
struct CrosspostCardRequest: Identifiable, Hashable {
    enum Kind: Hashable {
        /// Discord's own announcements — its Community Updates card.
        case communityUpdates
        /// Another server's — its profile card, named from the publisher.
        case server(GuildID, name: String)
    }

    var kind: Kind
    var anchor: CGRect

    var id: String {
        switch kind {
        case .communityUpdates: "community-updates"
        case .server(let guildID, _): "server-\(guildID.rawValue)"
        }
    }
}

extension AppModel {
    /// A crosspost's name or face, clicked: Discord's Community Updates card
    /// for its own announcements (`455207.MZ`), the publishing server's card
    /// for every other (`109026`).
    func openCrosspostAuthor(_ messageID: MessageID, in channelID: ChannelID, anchor: CGRect) {
        guard let message = message(messageID, in: channelID), message.isCrosspost else { return }
        dismissMessageSurfaces()
        if AuthorTag.isOfficialCrosspost(message) {
            crosspostCard = CrosspostCardRequest(kind: .communityUpdates, anchor: anchor)
        } else if let guildID = message.reference?.guildID {
            crosspostCard = CrosspostCardRequest(
                kind: .server(guildID, name: Self.publisherName(users[message.authorID]?.username ?? "")),
                anchor: anchor
            )
            loadGuildProfile(guildID)
        }
    }

    /// Discord's name for a crosspost's server while its profile is not in
    /// hand: the publishing webhook's, less its last word — "Wingcord
    /// #announcements" names "Wingcord".
    static func publisherName(_ username: String) -> String {
        let words = username.split(separator: " ")
        return words.count > 1 ? words.dropLast().joined(separator: " ") : username
    }
}

/// Discord's Community Updates card (`10364`): its logo, the staff badge with
/// "Community Updates", and the two lines about what the channel is.
///
/// **Discord's own pictures**: the logo on white and the blurple staff badge,
/// both taken from its assets. Nothing painted behind them — the popover
/// supplies the glass, §4.9.
struct CommunityUpdatesCard: View {
    var body: some View {
        VStack(spacing: 0) {
            if let logo = CrosspostArt.logo {
                Image(nsImage: logo)
                    .resizable()
                    .frame(width: 100, height: 100)
                    .clipShape(.rect(cornerRadius: 16, style: .continuous))
                    .accessibilityHidden(true)
            }
            HStack(spacing: Spacing.base) {
                if let badge = CrosspostArt.staffBadge {
                    Image(nsImage: badge)
                        .resizable()
                        .frame(width: 16, height: 16)
                        .help("Discord Staff")
                        .accessibilityLabel(Text("Discord Staff"))
                }
                Text("Community Updates")
                    .font(.system(.headline, weight: .semibold))
                    .foregroundStyle(Ink.primary)
            }
            .padding(.top, Spacing.margin)
            Text("Official announcements from Discord for Community Server admins and moderators.")
                .font(.system(.subheadline))
                .foregroundStyle(Ink.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Spacing.base)
            Text("We\u{2019}re here to help!")
                .font(.system(.subheadline))
                .foregroundStyle(Ink.secondary)
                .padding(.top, Spacing.base)
        }
        .padding(.vertical, 24)
        .padding(.horizontal, 16)
        .frame(width: 240)
    }
}

/// Discord's two pictures for the card, read from the bundle once each.
private enum CrosspostArt {
    @MainActor static let logo: NSImage? = image("community-updates", "png")
    @MainActor static let staffBadge: NSImage? = image("discord-staff", "svg")

    @MainActor private static func image(_ name: String, _ ext: String) -> NSImage? {
        Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Art")
            .flatMap(NSImage.init(contentsOf:))
    }
}

/// Presents a crosspost's card from the window root, at the author's rect —
/// the transcript is drawn, so it cannot hang a popover off a row itself.
struct CrosspostCardPresenter: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var model = model
        return content.popover(
            item: $model.crosspostCard,
            attachmentAnchor: .rect(.rect(model.crosspostCard?.anchor ?? .zero)),
            arrowEdge: .trailing
        ) { request in
            card(request)
                .environment(model)
                .presentationBackground(.clear)
        }
    }

    @ViewBuilder
    private func card(_ request: CrosspostCardRequest) -> some View {
        switch request.kind {
        case .communityUpdates:
            CommunityUpdatesCard()
        case .server(let guildID, let name):
            GuildProfileCard(
                profile: serverProfile(guildID, publisher: name),
                openGuild: { id in
                    model.crosspostCard = nil
                    model.openGuild(id)
                },
                retry: { model.retryGuildProfile(guildID) }
            )
            .appColorScheme()
        }
    }
}

extension CrosspostCardPresenter {
    /// The server's card, named from the publisher until the server answers —
    /// unless it answered that it will not, which Discord calls a private
    /// server.
    private func serverProfile(_ guildID: GuildID, publisher name: String) -> GuildProfilePresentation {
        var profile = model.guildProfilePresentation(of: guildID, tag: nil)
        if model.guildProfiles[guildID] == nil, model.guilds[guildID] == nil,
           profile.refusal != .limited, !name.isEmpty
        {
            profile.name = name
        }
        return profile
    }
}

extension View {
    /// Apply once, at the window root.
    func presentsCrosspostCards() -> some View {
        modifier(CrosspostCardPresenter())
    }
}
