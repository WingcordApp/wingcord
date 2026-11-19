import Foundation
import WingcordCore

// MARK: - Joining a server, and the gate that follows

extension AppModel {

    // MARK: What this server actually asks

    /// The questions asked **on the way in**, in the server's own order.
    ///
    /// `isInOnboarding` is the filter and it is the whole point — see
    /// `ServerJoinGate`. A prompt with no options is a heading over nothing and
    /// is dropped here rather than checked at every use.
    func joinGatePrompts(inGuild guildID: GuildID) -> [GuildOnboarding.Prompt] {
        guard let onboarding = guildOnboardings[guildID], onboarding.isEnabled else { return [] }
        return onboarding.prompts.filter { $0.isInOnboarding && !$0.options.isEmpty }
    }

    /// Whether this server still wants an agreement from the reader.
    ///
    /// **Both halves are required and the second is the one that was missing.**
    /// A server having rules is not a reason to ask: somebody who agreed when
    /// they joined is a full member, and `PUT /guilds/{id}/requests/@me` answers
    /// them *"This user is already a member, join request is already closed"* —
    /// which is a real refusal that a client offering the button has earned.
    /// `member.pending` is Discord's own bit for "has not agreed yet", and it is
    /// what gates the step.
    func joinGateHasRules(inGuild guildID: GuildID) -> Bool {
        guard let form = memberVerifications[guildID] else { return false }
        // A form that also asks questions is answered whole, in the
        // application — an agreement sent alone is a form the server refuses.
        return form.canSubmit && !form.asksQuestions && isPendingMember(inGuild: guildID)
    }

    /// The steps this server actually has, computed rather than assumed.
    ///
    /// **Discord's onboarding, step for step** (docs/BETA3.md §2.1): it appears
    /// only where a prompt is `in_onboarding`, opens on the first question, and
    /// where the server also screens its members, ends on the rules — agreed
    /// first when it is sent, as `forza onboarding.har` does. A server with
    /// rules and no questions gets Discord's rules window instead
    /// (`JoinApplicationSheet`), never this page, and a server with neither is
    /// simply entered. No steps means no gate.
    func joinGateSteps(inGuild guildID: GuildID) -> [ServerJoinGate.Step] {
        let prompts = joinGatePrompts(inGuild: guildID)
        guard !prompts.isEmpty else { return [] }
        var steps = prompts.indices.map(ServerJoinGate.Step.question)
        if joinGateHasRules(inGuild: guildID) { steps.append(.rules) }
        return steps
    }

    /// Whether a server has questions to put to a newcomer at all — Discord's
    /// test before it shows onboarding: with none, it shows nothing and the
    /// member simply lands (`817818`'s `h9`).
    func isGating(_ guildID: GuildID) -> Bool {
        !joinGatePrompts(inGuild: guildID).isEmpty
    }

    // MARK: Raising it

    /// Opens the gate for a server, if that server has one.
    ///
    /// Idempotent per guild: a second call while it is already up is the same
    /// gate, which is what lets both the join and the "opened an un-onboarded
    /// server" path call this without either knowing about the other.
    func openJoinGate(_ guildID: GuildID, inviteCode: String? = nil) {
        if joinGate?.guildID == guildID { return }
        // **Held, not shown**: `isJoinGateShown` waits for the questions. The
        // gate used to be on screen from this moment, before anything had
        // arrived — "0 questions about what you're here for".
        joinGate = ServerJoinGate(guildID: guildID, inviteCode: inviteCode)
        dismissedJoinGates.remove(guildID)
        sessionController.loadJoinGate(guildID, inviteCode: inviteCode)
    }

    /// Closes the gate without answering it.
    ///
    /// **Remembered for the session**, which is what stops it reappearing every
    /// time the reader clicks back onto a server they chose to skip past. The
    /// server is still gated — the rules row on the Server Guide and the pending
    /// banner both still say so — and it is offered again on the next launch.
    func dismissJoinGate() {
        guard let gate = joinGate else { return }
        dismissedJoinGates.insert(gate.guildID)
        joinGate = nil
    }

    /// Whether the gate should be the detail column right now.
    ///
    /// Deliberately **not** "is there a gate value": the gate belongs to one
    /// server, and selecting a different one must show that server rather than
    /// somebody else's questions.
    var isJoinGateShown: Bool {
        guard let gate = joinGate else { return false }
        return gate.guildID == selectedGuildID && isGating(gate.guildID)
    }

    /// Whether the detail column is a **takeover** — a surface that is not a
    /// page inside a server, and therefore has no channel list to sit beside.
    ///
    /// **One name for both cases, because it is one arrangement.** The gate and
    /// discovery both narrow the sidebar to the rail and both draw no chrome,
    /// and two flags checked in three places is how one of them ends up leaving
    /// a two-hundred-point hole beside a full-width page. The rail stays in
    /// both, deliberately: stepping away to another server and coming back is
    /// the point of these being destinations rather than modals.
    var isColumnTakenOver: Bool { isJoinGateShown || isDiscoveryShown || isJoinRequestShown }

    /// Offers the gate for a server the reader has opened.
    ///
    /// **Called from `guildDidOpen`, and gated three ways.** It must not fire
    /// for a server whose questions have not arrived yet (nothing to ask), one
    /// the reader has already dismissed this session, or one that is already
    /// showing a gate. The first is the important one: `isGating` reads tables
    /// that fill asynchronously, so this is called again as they land rather
    /// than once on selection.
    func offerJoinGateIfNeeded(_ guildID: GuildID) {
        settleJoiningGate(guildID)
        if offerJoinApplicationIfNeeded(guildID) { return }
        guard joinGate == nil,
              // **The server on screen, not merely the one that answered.**
              // These loaders finish on their own schedule, and stepping through
              // the rail can land an answer for a server left two clicks ago —
              // which would take the one gate slot and lock out the server the
              // reader is actually looking at.
              selectedGuildID == guildID,
              !dismissedJoinGates.contains(guildID),
              guilds[guildID] != nil,
              // A server being previewed is not one the reader is in, and its
              // gate is the preview banner's Join button rather than this.
              guildPreview?.guildID != guildID,
              isGating(guildID),
              hasUnansweredJoinGate(guildID)
        else { return }
        joinGate = ServerJoinGate(guildID: guildID)
        seedJoinGateSelection()
    }

    /// A join's gate, once both of its tables are in.
    ///
    /// **Questions go on, and nothing else waits on this page.** A server with
    /// questions keeps the gate (its rules last); one without any closes it and,
    /// for a pending member, opens Discord's rules window; one with neither is
    /// simply entered. Both loaders end in `offerJoinGateIfNeeded`, so this runs
    /// as the second of them lands (docs/BETA3.md §1.6).
    private func settleJoiningGate(_ guildID: GuildID) {
        guard let gate = joinGate, gate.guildID == guildID,
              guildOnboardings[guildID] != nil,
              memberVerifications[guildID] != nil,
              !isGating(guildID)
        else { return }
        joinGate = nil
        guard isPendingMember(inGuild: guildID), memberVerifications[guildID]?.canSubmit == true else { return }
        dismissedJoinGates.insert(guildID)
        openJoinApplication(guildID, inviteCode: gate.inviteCode)
    }

    /// Puts Discord's member verification window in front of a pending member —
    /// Discord opens its form wherever `V(guildId)` holds: pending, in a server
    /// with the gate on. Once a session, like the gate, and never over an
    /// application already waiting on a moderator.
    ///
    /// **Rules alone too**, not only a form with questions (docs/BETA3.md D1):
    /// that window is Discord's for both, and the onboarding page drew the rules
    /// of a server that asked nothing else. Where onboarding asks questions,
    /// their page puts the rules last and this waits for it.
    private func offerJoinApplicationIfNeeded(_ guildID: GuildID) -> Bool {
        guard selectedGuildID == guildID,
              joinApplicationRequest == nil,
              !dismissedJoinGates.contains(guildID),
              !pendingJoinRequestGuildIDs.contains(guildID),
              isPendingMember(inGuild: guildID),
              let form = memberVerifications[guildID]
        else { return false }
        if !form.asksQuestions {
            guard form.canSubmit, guildOnboardings[guildID] != nil, !isGating(guildID) else { return false }
        }
        dismissedJoinGates.insert(guildID)
        openJoinApplication(guildID)
        return true
    }

    /// Whether there is anything here the reader has not already been through.
    ///
    /// **Pending membership is unambiguous**: the rules are unagreed.
    ///
    /// **Questions are Discord's member flags, not the answers.** Opening a
    /// server raises its onboarding only for somebody who started it and never
    /// finished (`MemberFlags.isOnboardingUnfinished` — Discord's own test).
    /// This used to ask whether any question had an answer, and onboarding can
    /// be finished having chosen nothing — `forza onboarding.har` submits
    /// `onboarding_responses: []` — so a reader who skipped the optional
    /// questions was asked them again on every launch. Joining raises the gate
    /// on its own path, `openJoinGate`, and is not this.
    private func hasUnansweredJoinGate(_ guildID: GuildID) -> Bool {
        guard isGating(guildID) else { return false }
        if joinGateHasRules(inGuild: guildID) { return true }
        guard let userID = currentUserID,
              let flags = members[guildID]?[userID]?.flags
        else { return false }
        return flags.isOnboardingUnfinished
    }

    /// Fills the gate's answer set from the account's existing one, once.
    ///
    /// See `ServerJoinGate.selection` for why starting empty loses roles.
    func seedJoinGateSelection() {
        guard var gate = joinGate, !gate.isSeeded,
              let onboarding = guildOnboardings[gate.guildID]
        else { return }
        gate.selection = onboarding.responses
        gate.isSeeded = true
        joinGate = gate
    }

    // MARK: Answering it

    func toggleJoinGateOption(_ optionID: UInt64, inPrompt promptID: UInt64) {
        guard var gate = joinGate,
              let prompt = joinGatePrompts(inGuild: gate.guildID).first(where: { $0.id == promptID })
        else { return }

        if gate.selection.contains(optionID) {
            gate.selection.remove(optionID)
        } else {
            // A radio group clears the others **of this prompt only**. Clearing
            // globally would wipe the answers to every other prompt — the same
            // data loss the seed above guards against, arriving by another door.
            if prompt.isSingleSelect {
                for option in prompt.options { gate.selection.remove(option.id) }
            }
            gate.selection.insert(optionID)
        }
        // **Nothing is written here.** Unlike Channels & Roles, where each click
        // is a save, this collects an answer set and submits it once — a gate
        // that wrote on every click would apply half an answer to somebody who
        // backed out of it, and there is a Back control on every step precisely
        // so they can.
        gate.failure = nil
        joinGate = gate
    }

    /// Moves to the next step, or submits when there is no next step.
    ///
    /// **The refusal is enforced here, not only on the button.** A required
    /// question that has not been answered may not be walked past, and a
    /// disabled control is not what enforces that — Return in the sheet, a
    /// keyboard equivalent, and any later caller all reach this directly. A
    /// guard the view alone holds is a guard the next call site does not.
    func advanceJoinGate() {
        guard let gate = joinGate, !gate.isSubmitting else { return }
        let steps = joinGateSteps(inGuild: gate.guildID)
        let prompts = joinGatePrompts(inGuild: gate.guildID)
        guard !steps.isEmpty else { return }
        let here = steps.firstIndex(of: gate.step) ?? 0
        guard forward(at: here, steps: steps, prompts: prompts, gate: gate).isEnabled else { return }
        guard here + 1 < steps.count else {
            submitJoinGate()
            return
        }
        joinGate?.step = steps[here + 1]
    }

    func retreatJoinGate() {
        guard let gate = joinGate else { return }
        let steps = joinGateSteps(inGuild: gate.guildID)
        guard let here = steps.firstIndex(of: gate.step), here > 0 else { return }
        joinGate?.step = steps[here - 1]
    }

    /// Sends both halves and, on success, lands the reader on the server.
    ///
    /// **`isSubmitting` is set by the controller, not here.** It is cleared in
    /// that task's `defer`, and a flag raised on one side of a boundary and
    /// lowered on the other is a spinner that runs for ever the first time the
    /// far side returns early.
    func submitJoinGate() {
        guard let gate = joinGate, !gate.isSubmitting else { return }
        sessionController.submitJoinGate(
            gate,
            prompts: joinGatePrompts(inGuild: gate.guildID),
            verification: joinGateHasRules(inGuild: gate.guildID)
                ? memberVerifications[gate.guildID]
                : nil
        )
    }

    /// Where the reader is put once the gate is answered.
    ///
    /// **The Server Guide, and that is Discord's own landing.** It is the page
    /// that explains a server somebody has just arrived in, and after answering
    /// three questions about what they want to see, a channel picked by
    /// position is not an answer to any of them. A server with no guide falls
    /// back to whatever the sidebar would have selected.
    func finishJoinGate() {
        guard let gate = joinGate else { return }
        joinGate = nil
        dismissedJoinGates.remove(gate.guildID)
        // The roles the answers granted decide which channels are visible, and
        // the cached member record still says the account holds none of them.
        // Without this the server opens to the same short channel list it had
        // before the questions were answered, which reads as the gate having
        // done nothing.
        railRevision &+= 1
        sidebarRevision &+= 1
        if serverGuides[gate.guildID]?.isEmpty == false {
            selectGuild(gate.guildID)
            openSurface(.serverGuide)
        }
    }

    // MARK: - Presentation

    var joinGatePresentation: ServerJoinGatePresentation? {
        guard let gate = joinGate, let guild = guilds[gate.guildID] else { return nil }

        let prompts = joinGatePrompts(inGuild: gate.guildID)
        let steps = joinGateSteps(inGuild: gate.guildID)
        // No questions, no page: the gate is held until they arrive.
        guard !steps.isEmpty else { return nil }
        // The step the flow *thinks* it is on may have stopped existing — the
        // routes fill while the gate is open, so a server whose questions arrive
        // late can grow steps under a reader. Clamping rather than trusting is
        // what stops that photographing as a blank page.
        let index = steps.firstIndex(of: gate.step) ?? 0

        let body: ServerJoinGatePresentation.Body
        switch steps[index] {
        case .question(let position):
            guard prompts.indices.contains(position) else { return nil }
            body = .question(questionPresentation(prompts[position], gate: gate))
        case .rules:
            let rules = memberVerifications[gate.guildID]
            body = .rules(.init(detail: rules?.detail, rules: rules?.rules ?? []))
        }

        return ServerJoinGatePresentation(
            guildID: gate.guildID,
            serverName: guild.name,
            iconURL: guild.iconHash.flatMap {
                CDN.guildIcon(guildID: gate.guildID, hash: $0, side: Metrics.avatarProfile)
            },
            monogram: guild.monogram,
            coverURL: guild.bannerHash.flatMap {
                CDN.guildBanner(guildID: gate.guildID, hash: $0, width: 1200)
            },
            stepNumber: index + 1,
            stepCount: steps.count,
            body: body,
            isSubmitting: gate.isSubmitting,
            failure: gate.failure,
            canGoBack: index > 0,
            forward: forward(at: index, steps: steps, prompts: prompts, gate: gate)
        )
    }

    private func questionPresentation(
        _ prompt: GuildOnboarding.Prompt,
        gate: ServerJoinGate
    ) -> ServerJoinGatePresentation.Question {
        let counts = roleMemberCounts[gate.guildID] ?? [:]
        var options: [ServerJoinGatePresentation.Question.Option] = []
        options.reserveCapacity(prompt.options.count)
        for option in prompt.options {
            options.append(.init(
                id: option.id,
                title: option.title,
                detail: option.detail,
                glyph: glyph(
                    emojiID: option.emojiID,
                    emojiName: option.emojiName,
                    isAnimated: option.isEmojiAnimated,
                    fallback: "circle.grid.2x2"
                ),
                isSelected: gate.selection.contains(option.id),
                // **The largest of its roles, never the sum.** An option
                // granting two roles does not have two disjoint populations —
                // the same people typically hold both — so adding them
                // double-counts and can exceed the server's own size, which is
                // how a reassuring number becomes an obviously wrong one.
                memberCount: option.roleIDs.compactMap { counts[$0] }.max().flatMap { $0 > 0 ? $0 : nil }
            ))
        }

        return .init(
            promptID: prompt.id,
            title: prompt.title,
            guidance: prompt.guidance,
            isRequired: prompt.isRequired,
            options: options,
            grants: grantedRoleSentence(prompt, gate: gate)
        )
    }

    /// "You will receive the @Forza FR role."
    ///
    /// Scoped to the prompt on screen, because that is the choice being made
    /// right now — naming every role the whole flow would grant turns one
    /// consequence into a list nobody reads.
    private func grantedRoleSentence(
        _ prompt: GuildOnboarding.Prompt,
        gate: ServerJoinGate
    ) -> String? {
        let byID = roles[gate.guildID] ?? [:]
        var names: [String] = []
        for option in prompt.options where gate.selection.contains(option.id) {
            for roleID in option.roleIDs {
                guard let name = byID[roleID]?.name, !names.contains(name) else { continue }
                names.append(name)
            }
        }
        guard !names.isEmpty else { return nil }
        let list = ListFormatter.localizedString(byJoining: names.map { "@\($0)" })
        return names.count == 1
            ? "You will receive the \(list) role."
            : "You will receive the \(list) roles."
    }

    private func forward(
        at index: Int,
        steps: [ServerJoinGate.Step],
        prompts: [GuildOnboarding.Prompt],
        gate: ServerJoinGate
    ) -> ServerJoinGatePresentation.Forward {
        let isLast = index == steps.count - 1
        guard steps.indices.contains(index), case .question(let position) = steps[index],
              prompts.indices.contains(position)
        else { return isLast ? .finish : .next }

        let prompt = prompts[position]
        let isAnswered = prompt.options.contains { gate.selection.contains($0.id) }
        if prompt.isRequired && !isAnswered { return .blocked }
        if isLast { return .finish }
        return isAnswered ? .next : .skip
    }
}

// MARK: - Getting into a server you are looking at from the outside

/// One server's application form, asked for.
struct JoinApplicationRequest: Identifiable, Hashable {
    var guildID: GuildID
    /// The invite it was reached through, which the form's route takes.
    var inviteCode: String?

    var id: GuildID { guildID }
}

extension AppModel {

    /// The tag card's button: a look inside the server, or its application.
    ///
    /// **Two acts behind one button**, decided by the server rather than by
    /// the caller — see `guildEntry`. Discord's Join from a tag card is a
    /// preview (`join from server tag.har`); the membership is the preview's
    /// own Join, once the reader has seen the place.
    func enterGuild(_ guildID: GuildID) {
        guard guilds[guildID] == nil else { return openGuild(guildID) }
        switch guildEntry(for: guildID, profile: guildProfiles[guildID], isJoined: false) {
        // **The application, not the gate.** The gate is drawn in the detail
        // column of a server the reader is in, and this reader is not in it —
        // which is why Apply to Join used to do nothing at all.
        case .apply: openJoinApplication(guildID)
        case .join: previewFromGuildProfile(guildID)
        case .none, .pending: break
        }
    }

    /// Puts a server's application form on screen — Discord's
    /// `openMemberVerificationModal(guildId, _, inviteKey)`.
    ///
    /// The card or menu it was asked from closes first: the form is a sheet,
    /// and a popover left standing over it would be the thing with focus.
    func openJoinApplication(_ guildID: GuildID, inviteCode: String? = nil) {
        expressionInfoRequest = nil
        profileRequest = nil
        joinApplicationRequest = JoinApplicationRequest(guildID: guildID, inviteCode: inviteCode)
    }

    /// The server card at the head of its application form.
    ///
    /// **The tag card's own presentation where the reader has one**, which is
    /// Discord's choice too — its form shows the server's profile card when it
    /// is known. Somebody who arrived by invite has no profile yet, and the
    /// form's own `with_guild` answer names the server instead.
    func joinApplicationCard(
        for guildID: GuildID,
        outsider: JoinApplicationGuild?
    ) -> GuildProfilePresentation {
        var card = guildProfilePresentation(of: guildID, tag: nil)
        card.entry = .none
        guard guildProfiles[guildID] == nil, guilds[guildID] == nil, let outsider else { return card }
        card.name = outsider.name
        card.monogram = AppModel.monogram(of: outsider.name)
        card.iconURL = outsider.iconHash.flatMap {
            CDN.guildIcon(guildID: guildID, hash: $0, side: Metrics.avatarProfile)
        }
        card.description = outsider.description
        card.memberCount = outsider.memberCount
        card.onlineCount = outsider.onlineCount
        card.bannerColor = outsider.iconHash.flatMap {
            GuildBannerArt.paletteURL(guildID: guildID, iconHash: $0).flatMap { derivedPalettes[$0]?.first }
        }
        return card
    }
}
