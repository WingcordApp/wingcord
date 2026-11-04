import Foundation
import WingcordCore

/// A slash command's chip on a "used" line, pressed. The transcript is a drawn
/// canvas, so the click stops here with the chip's rect and
/// `InvokedCommandPresenter` opens the flyout over it.
struct InvokedCommandRequest: Identifiable, Equatable {
    let id = UUID()
    var channelID: ChannelID
    var messageID: MessageID
    /// The chip, in the window root's space.
    var anchor: CGRect
}

/// One run of the flyout's line — `InvokedCommand.Piece`, with its people,
/// channels and roles named.
struct CommandLineRun: Hashable {
    enum Kind: Hashable {
        case command
        case label
        case value
        /// In the mention's ink. A person's opens their profile.
        case mention(UserID?)
    }

    var text: String
    var kind: Kind
}

extension AppModel {
    /// A press on a "used" line's chip — Discord's split (`es` in `217424`): a
    /// slash command's opens the command as it was run, an activity's the app
    /// launcher at the app (`OPEN_APP_LAUNCHER`), a label's nothing.
    func pressCommandChip(on messageID: MessageID, in channelID: ChannelID, anchor: CGRect) {
        guard let message = messages(in: channelID)?.messages.first(where: { $0.id == messageID }),
              let chip = message.commandHeaderChip
        else { return }
        switch chip {
        case .command:
            invokedCommandRequest = InvokedCommandRequest(channelID: channelID, messageID: messageID, anchor: anchor)
        case .activity, .startedActivity:
            openApplicationLauncher(message.componentApplicationID, in: channelID)
        case .label:
            break
        }
    }

    /// The line the flyout draws. Nil when the message is gone — deleted under
    /// the open flyout.
    ///
    /// **Never empty, and never waiting on the route.** The message itself names
    /// the command, so that much is up at once, and stays up if the route has
    /// nothing to say — an ephemeral answer has no record behind it at all.
    func commandLine(for request: InvokedCommandRequest) -> [CommandLineRun]? {
        guard let message = messages(in: request.channelID)?.messages.first(where: { $0.id == request.messageID }),
              let interaction = message.interaction
        else { return nil }
        let command = invokedCommands[request.messageID] ?? InvokedCommand(name: interaction.name)
        let guildID = channelIndex.guildID(of: request.channelID)
        return command.pieces.map { piece in
            switch piece {
            case .command(let text): CommandLineRun(text: text, kind: .command)
            case .label(let text): CommandLineRun(text: text, kind: .label)
            case .value(let value): commandLineRun(for: value, inGuild: guildID)
            }
        }
    }

    /// One option's value, as Discord's popout writes it: `@nick`, `#channel`,
    /// `@role`, `[attachment]`. **An id nobody here can name is shown as the id**,
    /// which is what Discord's does.
    private func commandLineRun(for value: InvokedOption.Value, inGuild guildID: GuildID?) -> CommandLineRun {
        func person(_ id: UserID) -> CommandLineRun? {
            guard let user = users[id] else { return nil }
            let name = guildID.flatMap { members[$0]?[id] }?.resolvedName(user: user) ?? user.preferredName
            return CommandLineRun(text: "@" + name, kind: .mention(id))
        }
        func role(_ id: RoleID) -> CommandLineRun? {
            guard let guildID, let role = roles[guildID]?[id] else { return nil }
            return CommandLineRun(text: "@" + role.name, kind: .mention(nil))
        }
        switch value {
        case .text(let text):
            return CommandLineRun(text: text, kind: .value)
        case .user(let id):
            return person(id) ?? CommandLineRun(text: String(id.rawValue), kind: .value)
        case .channel(let id):
            guard let channel = channelIndex[id] else {
                return CommandLineRun(text: String(id.rawValue), kind: .value)
            }
            return CommandLineRun(text: "#" + displayName(of: channel), kind: .mention(nil))
        case .role(let id):
            return role(id) ?? CommandLineRun(text: String(id.rawValue), kind: .value)
        case .mentionable(let id):
            // A role first, as Discord looks.
            return role(RoleID(rawValue: id))
                ?? person(UserID(rawValue: id))
                ?? CommandLineRun(text: String(id), kind: .value)
        case .attachment:
            return CommandLineRun(text: "[attachment]", kind: .value)
        }
    }
}
