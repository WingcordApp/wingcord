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
        memberVerifications[guildID]?.canSubmit == true && isPendingMember(inGuild: guildID)
    }

    /// The steps this server actually has, computed rather than assumed.
    ///
    /// **Either gate can exist alone**, and most servers have exactly one of
    /// them — so a flow with a fixed shape would show an empty question step or
    /// silently skip an agreement. The welcome is always first because it is the
    /// only step that names the server.
    func joinGateSteps(inGuild guildID: GuildID) -> [ServerJoinGate.Step] {
        var steps: [ServerJoinGate.Step] = [.welcome]
        steps.append(contentsOf: joinGatePrompts(inGuild: guildID).indices.map(ServerJoinGate.Step.question))
        if joinGateHasRules(inGuild: guildID) { steps.append(.rules) }
        return steps
    }

    /// Whether a server has anything to gate on at all.
    ///
    /// A server that asks nothing and demands nothing must never see this
    /// surface: the welcome step alone is a screen that says hello and then has
    /// nowhere to go, which is worse than landing in a channel.
    func isGating(_ guildID: GuildID) -> Bool {
        !joinGatePrompts(inGuild: guildID).isEmpty || joinGateHasRules(inGuild: guildID)
    }

    // MARK: Raising it

    /// Opens the gate for a server, if that server has one.
    ///
    /// Idempotent per guild: a second call while it is already up is the same
    /// gate, which is what lets both the join and the "opened an un-onboarded
    /// server" path call this without either knowing about the other.
    func openJoinGate(_ guildID: GuildID, inviteCode: String? = nil) {
        if joinGate?.guildID == guildID { return }
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
        return gate.guildID == selectedGuildID
    }

    /// Offers the gate for a server the reader has opened.
    ///
    /// **Called from `guildDidOpen`, and gated three ways.** It must not fire
    /// for a server whose questions have not arrived yet (nothing to ask), one
    /// the reader has already dismissed this session, or one that is already
    /// showing a gate. The first is the important one: `isGating` reads tables
    /// that fill asynchronously, so this is called again as they land rather
    /// than once on selection.
    func offerJoinGateIfNeeded(_ guildID: GuildID) {
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

    /// Whether there is anything here the reader has not already answered.
    ///
    /// **A server whose questions are all answered and whose rules are agreed is
    /// not gating**, and re-asking is how a client nags somebody about a server
    /// they set up months ago. Pending membership is unambiguous. Questions are
    /// judged on whether *any* join-flow prompt has been answered — Discord's
    /// own signal for "has been through onboarding here" is the `seen` map, and
    /// this client does not read it back per prompt, so the honest local test is
    /// whether the account holds an answer to any of them.
    private func hasUnansweredJoinGate(_ guildID: GuildID) -> Bool {
        if joinGateHasRules(inGuild: guildID) { return true }
        let prompts = joinGatePrompts(inGuild: guildID)
        guard !prompts.isEmpty else { return false }
        let answered = guildOnboardings[guildID]?.responses ?? []
        return !prompts.contains { prompt in
            prompt.options.contains { answered.contains($0.id) }
        }
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
        guard let here = steps.firstIndex(of: gate.step),
              forward(at: here, steps: steps, prompts: prompts, gate: gate).isEnabled
        else { return }
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
        let hasRules = joinGateHasRules(inGuild: gate.guildID)
        // The step the flow *thinks* it is on may have stopped existing — the
        // routes fill while the gate is open, so a server whose questions arrive
        // late can grow steps under a reader already past the welcome. Clamping
        // rather than trusting is what stops that photographing as a blank page.
        let index = steps.firstIndex(of: gate.step) ?? 0

        let body: ServerJoinGatePresentation.Body
        switch steps.indices.contains(index) ? steps[index] : .welcome {
        case .welcome:
            body = .welcome(.init(promise: welcomePromise(questions: prompts.count, hasRules: hasRules)))
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

    /// "One question about what you're here for, then this server's rules."
    private func welcomePromise(questions: Int, hasRules: Bool) -> String {
        switch (questions, hasRules) {
        case (0, true): "Just this server's rules to read, and you're in."
        case (1, true): "One question about what you're here for, then this server's rules."
        case (1, false): "One question about what you're here for, and that's it."
        case (let count, true): "\(count) questions about what you're here for, then this server's rules."
        case (let count, false): "\(count) questions about what you're here for, and that's it."
        }
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
