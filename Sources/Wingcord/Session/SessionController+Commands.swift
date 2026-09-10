import Foundation
import WingcordCore
import WingcordNet

// MARK: - Slash commands
//
// Two things happen here: the index is fetched the first time a channel's `/`
// list is asked for, and a chosen command is posted as an interaction.
//
// Nothing polls. The index carries a `version` Discord bumps when anything in it
// changes, and the socket dispatches `GUILD_APPLICATION_COMMAND_INDEX_UPDATE`
// when a server's moves — so refetching on a timer would be spending requests to
// learn something the wire already says. This client fetches once per scope per
// session, which is what the capture's own client did.

/// An interaction posted and not yet answered.
///
/// **`POST /interactions` answers `204` with an empty body.** Whether the
/// application took the command is said only by the socket — `INTERACTION_SUCCESS`
/// about four hundred milliseconds later, or `INTERACTION_FAILURE`. A client
/// that treats the `204` as success tells the reader a command ran when the bot
/// may never have seen it.
struct PendingInteraction: Hashable, Sendable, Identifiable {
    var nonce: String
    var channelID: ChannelID
    /// `/8ball`, as the banner draws it.
    var label: String
    var applicationName: String
    /// Set when the socket said the application refused, or when nothing
    /// answered inside the window. The row stays up a moment longer so the
    /// reader sees *why* nothing happened.
    var failed = false

    var id: String { nonce }
}

extension SessionController {

    // MARK: The index

    /// Fills the indexes a channel's `/` list needs, once each.
    ///
    /// **Guarded per scope, not per call.** The `/` list asks for this on every
    /// open, and in a server two scopes answer it — refetching either would be
    /// 119 KB for a list that has not changed since the reader signed in.
    func loadCommandIndex(for channelID: ChannelID) async {
        let scopes = model.commandScopes(for: channelID).filter { model.commandIndexes[$0] == nil }
        guard !scopes.isEmpty else {
            await loadCommandFrecency()
            return
        }
        for scope in scopes {
            do {
                let index = try await rest.commandIndex(scope)
                model.commandIndexes[scope] = index
                model.commandRevision &+= 1
                Self.trace("commands: \(scope) → \(index.commands.count) commands, "
                    + "\(index.applications.count) apps")
            } catch {
                // **Stored as an empty index rather than left absent.** Absent
                // means "not asked", so the list would ask again on every
                // keystroke and be refused identically every time.
                model.commandIndexes[scope] = CommandIndex()
                model.commandRevision &+= 1
                Self.trace("commands: \(scope) failed — \(Self.describe(error))")
            }
        }
        await loadCommandFrecency()
    }

    /// One application's own commands, for its page in the apps flyout.
    ///
    /// The app-scoped route — 7,700 bytes for OwO against the account index's
    /// 119 KB. Guarded like every other scope, and the frecency table comes with
    /// it because the page's Recents section is drawn from it.
    func loadAppCommandIndex(for id: ApplicationID) async {
        let scope = DiscordREST.CommandScope.application(id)
        if model.commandIndexes[scope] == nil {
            do {
                model.commandIndexes[scope] = try await rest.commandIndex(scope)
            } catch {
                // Stored as empty rather than left absent, for the reason the
                // channel index is: absent means "not asked".
                model.commandIndexes[scope] = CommandIndex()
                Self.trace("commands: \(id) failed — \(Self.describe(error))")
            }
            model.commandRevision &+= 1
        }
        await loadCommandFrecency()
    }

    /// The account's own Frequently Used table.
    ///
    /// Its own guard, because it is a different route from the index and one of
    /// them failing must not cost the other. An account that has never run a
    /// command answers an empty table, which is a real answer — so the latch is
    /// a flag rather than "is the array empty".
    func loadCommandFrecency() async {
        guard !hasLoadedCommandFrecency else { return }
        hasLoadedCommandFrecency = true
        do {
            model.commandFrecency = try await rest.commandFrecency()
            model.commandRevision &+= 1
        } catch {
            Self.trace("commands: frecency failed — \(Self.describe(error))")
        }
    }

    // MARK: Running one

    /// Posts a chosen command as an interaction.
    ///
    /// The banner goes up **before** the request and comes down on the socket's
    /// answer, for the reason the activity launch registers its waiter first:
    /// Discord's acknowledgement can arrive before the `await` on the POST even
    /// resumes, and an answer with nowhere to go is dropped.
    func runCommand(
        _ pending: PendingCommand,
        in channelID: ChannelID,
        origin: CommandInvocation.Origin = .slashUI
    ) async {
        guard let sessionID = await socketSessionID() else {
            model.reportActionFailure("Not connected.")
            return
        }
        let leaf = pending.command
        let nonce = Self.nonce()
        let application = model.commandApplicationName(for: leaf.applicationID)

        model.pendingInteractions[nonce] = PendingInteraction(
            nonce: nonce,
            channelID: channelID,
            label: "/" + leaf.name,
            applicationName: application
        )
        // The reader ran it, so it belongs at the top of Frequently Used now —
        // not whenever Discord's own client next writes the table back.
        model.commandUses[leaf.id] = .now
        model.commandRevision &+= 1

        do {
            try await rest.sendCommand(
                CommandInvocation(
                    command: leaf,
                    arguments: pending.arguments,
                    guildID: model.channelIndex[channelID]?.guildID,
                    channelID: channelID,
                    sessionID: sessionID,
                    nonce: nonce,
                    origin: origin
                )
            )
        } catch {
            model.pendingInteractions[nonce] = nil
            model.reportActionFailure(
                Self.reason(for: error, verb: "run /\(leaf.name)")
            )
            return
        }
        await awaitInteraction(nonce: nonce)
    }

    /// Presses a button an application attached to a message.
    ///
    /// The same route, the same banner and the same acknowledgement as a command
    /// — a component press *is* an interaction, and the only thing that differs
    /// is the body. What comes back is almost always a `MESSAGE_UPDATE` editing
    /// the message the button sits on, which the timeline already applies: the
    /// pager in the capture redraws in place five times without a single new row.
    func pressComponent(_ component: MessageComponent, on message: Message) async {
        guard let customID = component.customID else { return }
        guard let sessionID = await socketSessionID() else {
            model.reportActionFailure("Not connected.")
            return
        }
        let nonce = Self.nonce()
        let applicationID = message.componentApplicationID

        model.pendingInteractions[nonce] = PendingInteraction(
            nonce: nonce,
            channelID: message.channelID,
            // The button's own words. A `custom_id` is the application's opaque
            // string — `help_page__next,987654321987654321` — and putting that
            // in front of a reader would be showing them a token, not a label.
            label: component.label.isEmpty ? "that button" : "“\(component.label)”",
            // The application's own display name, from whoever posted the
            // message — an interaction response's author IS the app. The
            // command index answers for a bot whose commands were fetched;
            // neither is guaranteed, so both are tried before the bare id.
            applicationName: model.users[message.authorID]?.preferredName
                ?? model.commandApplicationName(for: applicationID)
        )

        do {
            try await rest.pressComponent(
                ComponentInteraction(
                    customID: customID,
                    componentType: ComponentInteraction.buttonComponentType,
                    message: message,
                    applicationID: applicationID,
                    guildID: model.channelIndex[message.channelID]?.guildID,
                    sessionID: sessionID,
                    nonce: nonce
                )
            )
        } catch {
            model.pendingInteractions[nonce] = nil
            model.reportActionFailure(Self.reason(for: error, verb: "press that button"))
            return
        }
        await awaitInteraction(nonce: nonce)
    }

    /// Takes the banner down when the socket answers, or when nothing does.
    ///
    /// **The timeout is generous and it is not a failure of the command.** An
    /// application has three seconds to acknowledge and fifteen minutes to
    /// follow up; what this waits for is the acknowledgement, and a bot that
    /// misses it is a bot the reader should be told about rather than one this
    /// client should keep waiting on silently.
    private func awaitInteraction(nonce: String) async {
        try? await Task.sleep(for: .seconds(Self.interactionTimeout))
        guard var pending = model.pendingInteractions[nonce] else { return }
        pending.failed = true
        model.pendingInteractions[nonce] = pending
        clearInteraction(nonce: nonce, after: Self.failureLinger)
    }

    /// `INTERACTION_SUCCESS` — the application took it. The banner's work is
    /// done; whatever it answers with arrives as an ordinary message.
    func resolveInteraction(nonce: String?) {
        guard let nonce, model.pendingInteractions[nonce] != nil else { return }
        model.pendingInteractions[nonce] = nil
    }

    /// `INTERACTION_FAILURE` — the application refused, or let the window close.
    ///
    /// The dispatch is `{id, nonce}` and nothing more, so what the reader is
    /// told is that the command did not run. Inventing a reason here would be
    /// inventing one.
    func failInteraction(nonce: String?) {
        guard let nonce, var pending = model.pendingInteractions[nonce] else { return }
        pending.failed = true
        model.pendingInteractions[nonce] = pending
        clearInteraction(nonce: nonce, after: Self.failureLinger)
    }

    private func clearInteraction(nonce: String, after delay: Double) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, model.pendingInteractions[nonce]?.failed == true else { return }
            model.pendingInteractions[nonce] = nil
        }
    }

    /// How long to wait for the acknowledgement. Discord gives an application
    /// three seconds to answer or defer; this allows for a slow round trip on
    /// top of that rather than racing it.
    static let interactionTimeout: Double = 12
    /// How long a failed command's banner stays up. Long enough to read, short
    /// enough that it is gone before the reader types the next thing.
    static let failureLinger: Double = 5
}

extension AppModel {
    /// The name of the application a command belongs to, from whichever index
    /// carried it. Falls back to the id — a command whose application this
    /// client never learned the name of is still runnable.
    func commandApplicationName(for id: ApplicationID) -> String {
        for index in commandIndexes.values {
            if let application = index.applications.first(where: { $0.id == id }) {
                return application.name
            }
        }
        return id.description
    }
}

extension SessionController {

    /// Runs a context command on a message or on a person.
    ///
    /// **The same banner and the same acknowledgement as a chat-input
    /// command**, because it is the same interaction: registered before the
    /// request, since Discord's answer can arrive before the `await` on the
    /// POST resumes and an answer with nowhere to go is dropped. §S.8 — a 204
    /// says nothing, and the socket is the only oracle.
    func runContextCommand(
        _ command: ApplicationCommand,
        on target: AppCommandTarget,
        in channelID: ChannelID
    ) {
        Task { [weak self] in
            guard let self else { return }
            guard let sessionID = await socketSessionID() else {
                model.reportActionFailure("Not connected.")
                return
            }
            let nonce = Self.nonce()
            model.pendingInteractions[nonce] = PendingInteraction(
                nonce: nonce,
                channelID: channelID,
                // No slash: this is not something anybody typed, and calling
                // it "/Make it a Quote" would name a command that does not
                // exist in the composer.
                label: command.name,
                applicationName: model.commandApplicationName(for: command.applicationID)
            )
            do {
                try await rest.runContextCommand(
                    ContextCommandInvocation(
                        command: command,
                        targetID: target.targetID,
                        guildID: model.channelIndex[channelID]?.guildID,
                        channelID: channelID,
                        sessionID: sessionID,
                        nonce: nonce
                    )
                )
            } catch {
                model.pendingInteractions[nonce] = nil
                model.reportActionFailure(
                    Self.reason(for: error, verb: "run \(command.name)")
                )
                return
            }
            await awaitInteraction(nonce: nonce)
        }
    }
}
