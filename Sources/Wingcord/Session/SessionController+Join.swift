import Foundation
import WingcordCore
import WingcordNet

// Joining a server, and answering the gate that follows.
//
// The whole sequence is captured — `forza onboarding1.har` — and the order below
// is the capture's, not a reconstruction of it:
//
// ```
// 15:21:21.710  GET  /invites/forza?…               the preview card
// 15:21:22.021  POST /invites/forza                 → 400, captcha
// 15:21:29.189  POST /invites/forza  +3 headers     → 200, joined
// 15:21:30.692  GET  /guilds/{id}/new-member-welcome
// 15:21:30.815  GET  /guilds/{id}/onboarding
// 15:21:31.304  GET  /guilds/{id}/roles/member-counts
// 15:21:34.329  GET  /guilds/{id}/member-verification?…&invite_code=forza
// 15:21:53.090  PUT  /guilds/{id}/requests/@me      the rules
// 15:21:53.428  POST /guilds/{id}/onboarding-responses
// ```

extension SessionController {

    // MARK: The sheet

    /// Looks up whatever is in the Add a Server field.
    ///
    /// **Debounced and last-write-wins.** Somebody typing a code produces one of
    /// these per keystroke, and an answer for a prefix of what is now typed is
    /// worse than no answer — it draws a card for a server nobody asked about.
    /// The task is replaced rather than queued, and the answer is dropped unless
    /// the field still holds the code it was asked about.
    func resolveInvite(_ input: String) {
        inviteLookupTask?.cancel()
        guard let code = InvitePreview.code(in: input) else {
            model.joinServerSheet?.lookup = .idle
            return
        }
        // Already answered for exactly this code. Re-asking on every keystroke
        // past the end of a pasted link is a request per character for an answer
        // already on screen.
        if case .found(let preview) = model.joinServerSheet?.lookup, preview.code == code {
            return
        }
        model.joinServerSheet?.lookup = .looking(code)

        inviteLookupTask = Task { [weak self] in
            // Long enough that typing a seven-character code asks once, short
            // enough that a paste feels immediate.
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled, let self else { return }
            do {
                let preview = try await rest.resolveInvite(code, input: input)
                guard !Task.isCancelled, model.joinServerSheet?.code == code else { return }
                model.joinServerSheet?.lookup = .found(preview)
            } catch {
                guard !Task.isCancelled, model.joinServerSheet?.code == code else { return }
                Self.trace("invite \(code) failed: \(Self.describe(error))")
                model.joinServerSheet?.lookup = .failed(
                    code: code,
                    message: Self.inviteFailure(error)
                )
            }
        }
    }

    /// Joins the server the sheet is showing.
    ///
    /// **The gateway session id is the whole body**, and without a socket there
    /// is nothing to join with: the `GUILD_CREATE` that actually delivers the
    /// server is dispatched to that session, so a join sent without one lands a
    /// membership the client cannot see.
    ///
    /// A captcha on the way is not handled here. `DiscordREST` recognises the
    /// challenge, puts it on screen through `CaptchaSolver`, and retries — so by
    /// the time this resumes, the join either happened or was refused for a
    /// reason worth showing.
    func joinServer(_ preview: InvitePreview) {
        guard model.joinServerSheet?.isJoining != true else { return }
        model.joinServerSheet?.isJoining = true
        model.joinServerSheet?.joinFailure = nil

        Task { [weak self] in
            guard let self else { return }
            defer { model.joinServerSheet?.isJoining = false }

            guard let sessionID = await socket?.currentSessionID else {
                model.joinServerSheet?.joinFailure = "Not connected. Try again in a moment."
                return
            }

            let acceptance: InviteAcceptance
            do {
                acceptance = try await rest.acceptInvite(preview.code, sessionID: sessionID)
            } catch {
                Self.trace("join \(preview.code) failed: \(Self.describe(error))")
                model.joinServerSheet?.joinFailure = Self.joinFailure(error)
                return
            }

            model.joinServerSheet = nil
            await land(acceptance, code: preview.code)
        }
    }

    /// Joins the server an invite card in a message points at — Discord's
    /// `acceptInviteAndTransitionToInviteChannel`, with the context its embed
    /// sends ("Invite Button Embed").
    ///
    /// **The join sheet's own accept**, so a captcha, the rules gate and the
    /// onboarding questions arrive exactly as they do from Add a Server. Once
    /// per code at a time: a second press while the first is out is not a
    /// second join.
    func joinFromInviteCard(_ card: InviteCard) {
        guard inviteCardJoins.insert(card.code).inserted else { return }
        Task { [weak self] in
            guard let self else { return }
            defer { inviteCardJoins.remove(card.code) }
            guard let sessionID = await socket?.currentSessionID else {
                model.reportActionFailure("Not connected. Try again in a moment.")
                return
            }
            do {
                let acceptance = try await rest.acceptInvite(
                    card.code, sessionID: sessionID, source: "Invite Button Embed"
                )
                await land(acceptance, code: card.code)
            } catch {
                Self.trace("join \(card.code) from card failed: \(Self.describe(error))")
                model.reportActionFailure(Self.joinFailure(error))
            }
        }
    }

    /// Takes the reader into a server an accept has just joined.
    private func land(_ acceptance: InviteAcceptance, code: String) async {
        // **Wait for the socket, not for the 200.** The response carries the
        // invite's guild half and none of the server's contents; the rail
        // tile, the channel list and the roles all come from the
        // `GUILD_CREATE` that follows. Selecting before it lands would open
        // a server with no channels.
        let arrived = await waitForGuild(acceptance.guildID)
        model.selectGuild(acceptance.guildID)
        // **The invite's own channel, when the reader may read it.** An
        // invite points somewhere on purpose — the captured one at `#rules`
        // — and landing on whatever the sidebar would have picked by
        // position throws that away. A gate, if there is one, takes the
        // column from underneath this a line later; the channel is still the
        // right thing to be behind it.
        if let channelID = acceptance.channelID, model.canOpen(channelID) {
            model.selectChannel(channelID)
        }

        guard arrived else {
            // Joined, and the socket said nothing this client could read.
            // The membership is real and the next launch will have it; there
            // is nothing useful to put on screen for it now.
            Self.trace("join \(code): no GUILD_CREATE")
            return
        }

        // **`new_member` decides whether to ask.** Re-accepting an invite to
        // a server you are already in succeeds, and treating that as a fresh
        // join is how a client asks a three-year member to read the rules
        // again. `openJoinGate` still checks the server actually gates.
        guard acceptance.isNewMember || acceptance.requiresVerification else { return }
        model.openJoinGate(acceptance.guildID, inviteCode: code)
    }

    // MARK: The gate

    /// Fetches the four things the gate is computed from.
    ///
    /// Concurrent, because they are independent routes in different rate-limit
    /// buckets and the gate waits on the slowest either way. Each loader is
    /// itself deduplicated, so this is safe to call for a server whose questions
    /// a rail hover already asked for.
    ///
    /// - Parameter inviteCode: passed to the rules route, which takes one. See
    ///   `DiscordREST.memberVerification(of:inviteCode:)`.
    func loadJoinGate(_ guildID: GuildID, inviteCode: String?) {
        loadOnboarding(guildID)
        loadServerGuide(guildID)
        // The counts are what let an option say how many people chose it, and
        // the gate is the one place that number changes a decision.
        loadRoleMemberCounts(guildID)
        loadMemberVerification(guildID, inviteCode: inviteCode)
    }

    /// Sends both halves of the gate, **in the captured order**.
    ///
    /// **Rules first, answers second**, and the order is not a preference. The
    /// capture does it in that order 338 ms apart, and there is a mechanism
    /// behind it: agreeing is what clears `pending`, and a pending member is not
    /// a full member. Sending the ballot first risks a route refusing an account
    /// that has not passed the server's own gate yet — and the failure that
    /// produces is "the questions did nothing", with no surface still offering
    /// to ask them.
    ///
    /// The reverse order fails better in the other direction and that is the
    /// trade being taken knowingly: rules through, answers refused, leaves
    /// somebody in the server with their questions unanswered — recoverable from
    /// Channels & Roles, which is exactly where those questions also live.
    func submitJoinGate(
        _ gate: ServerJoinGate,
        prompts: [GuildOnboarding.Prompt],
        verification: MemberVerification?
    ) {
        let guildID = gate.guildID
        guard joinGateSubmissions.insert(guildID).inserted else { return }
        model.joinGate?.isSubmitting = true
        model.joinGate?.failure = nil

        Task { [weak self] in
            guard let self else { return }
            defer {
                joinGateSubmissions.remove(guildID)
                model.joinGate?.isSubmitting = false
            }

            if let verification {
                do {
                    let outcome = try await rest.agreeToRules(verification, inGuild: guildID)
                    switch outcome {
                    case .approved:
                        // The gateway's `GUILD_MEMBER_UPDATE` is the authority and
                        // lands a beat later, but the gate has to close on the
                        // click rather than on the round trip.
                        if let userID = model.currentUserID {
                            model.members[guildID]?[userID]?.isPending = false
                            // A pending member is masked as a lurker is — see
                            // `PermissionGate.lurkerMask` — so agreeing opens the channels.
                            model.permissionGate.invalidate()
                            model.memberRevision &+= 1
                        }
                    case .rejected(let reason):
                        model.joinGate?.failure = reason
                            ?? "This server turned the request down."
                        return
                    case .pending, .unknown:
                        // A server that also reviews applications leaves this
                        // open. The answers below are still worth sending — they
                        // are what the moderator will be looking at.
                        break
                    }
                } catch {
                    Self.trace("gate rules \(guildID) failed: \(Self.describe(error))")
                    model.joinGate?.failure = Self.gateFailure(error)
                    return
                }
            }

            if !prompts.isEmpty {
                do {
                    let applied = try await rest.setOnboardingResponses(
                        gate.selection,
                        // **Only the prompts this gate drew.** `seen` means
                        // shown, and the capture proves it: one prompt of six.
                        // See `OnboardingResponsesBody`.
                        prompts: prompts,
                        inGuild: guildID
                    )
                    model.guildOnboardings[guildID]?.responses = applied
                } catch {
                    Self.trace("gate answers \(guildID) failed: \(Self.describe(error))")
                    model.joinGate?.failure = Self.gateFailure(error)
                    return
                }
            }

            guard model.joinGate?.guildID == guildID else { return }
            model.finishJoinGate()
        }
    }

    // MARK: Reading a refusal

    /// Why an invite would not resolve, in words somebody can act on.
    ///
    /// Discord answers a dead invite with a 404 and a live one the account is
    /// banned from with a 403, and neither carries a sentence worth showing.
    static func inviteFailure(_ error: any Error) -> String {
        switch error as? DiscordREST.Failure {
        case .notFound:
            "That invite has expired, or there's no server behind it."
        case .forbidden:
            "You can't join that server."
        case .api(_, _, let message?) where !message.isEmpty:
            message
        case .transport:
            "Couldn't reach Discord. Check your connection."
        default:
            "That invite didn't work."
        }
    }

    /// Why a join was refused.
    static func joinFailure(_ error: any Error) -> String {
        switch error as? DiscordREST.Failure {
        case .api(_, _, let message?) where !message.isEmpty:
            message
        case .forbidden:
            "You can't join that server."
        case .notFound:
            "That invite has expired."
        case .transport:
            "Couldn't reach Discord. Check your connection."
        default:
            "That didn't go through. Try again in a moment."
        }
    }

    /// Why the gate's submit failed.
    ///
    /// Discord's own sentence where it sent one — *"This user is already a
    /// member, join request is already closed"* is a real answer that says
    /// exactly what happened — and one honest fallback otherwise.
    static func gateFailure(_ error: any Error) -> String {
        switch error as? DiscordREST.Failure {
        case .api(_, _, let message?) where !message.isEmpty:
            message
        case .transport:
            "Couldn't reach Discord. Check your connection."
        // **Told apart from the generic case deliberately.** A 403 here is what
        // the wrong HTTP method looked like for as long as this client sent one
        // — see `DiscordREST.setOnboardingResponses` — and one sentence covering
        // "refused", "gone" and "could not be read" is what made that take a
        // live join and a trace to find.
        case .forbidden:
            "Discord wouldn't accept that."
        case .notFound:
            "This server's questions have changed. Reopen it and try again."
        default:
            "That didn't go through. Try again in a moment."
        }
    }
}
