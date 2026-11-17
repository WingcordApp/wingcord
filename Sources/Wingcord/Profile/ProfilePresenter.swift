import SwiftUI
import WingcordCore

/// The one place a profile is presented.
///
/// Attached at the window root and nowhere else. Every row that can open a
/// profile — a member row, a message avatar, a mention — sets
/// `AppModel.profileRequest` and stops there, which is what keeps presentation
/// modifiers off the rows themselves. A `.popover` written inline in a member
/// row is a popover *per row*, evaluated as part of every row's body on every
/// evaluation, including its content closure's captures.
///
/// **The card is a layer in the window, not a `.popover` or a `.sheet`, and
/// that is a correction.** It was both, for good reasons that are still true of
/// everything else the app presents. What broke them is a profile frame: its
/// artwork is authored to hang *past* the card, and a system presentation
/// cannot show that at all. Two separate reasons, either one fatal:
///
///  1. **A presentation is an `NSWindow`, and a window cannot draw outside
///     itself.** Whatever room the card does not ask for does not exist.
///  2. **Asking for the room does not help**, because a popover and a sheet
///     both paint their own backdrop material behind the whole of their
///     content, and `.presentationBackground(.clear)` does not suppress it.
///     Measured three ways — see `INVARIANTS.md`. Reserving a margin for the
///     artwork produced a grey panel around the card instead of roses over the
///     transcript.
///
/// So the four things a popover was being kept for are done here instead, and
/// none of them needed the machinery its doc comment used to warn about:
///
///  - **anchoring** and **staying on screen** — `ProfileCardPlacement`, pure
///    arithmetic over a rect the store already carries in the root's own space.
///  - **outside-click and Escape** — one `Button` filling the window behind the
///    card, carrying `.keyboardShortcut(.cancelAction)`. No local `NSEvent`
///    monitor, so nothing has to be torn down by hand and no closure outlives
///    the card.
///  - **first responder** — never taken, because no window is created.
///
/// It is also strictly cheaper: a popover allocates a window per card, and this
/// allocates nothing, so the card now materialises with the app's own motion
/// rather than the system's generic one.
struct ProfilePresenter: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion

    /// The draft, alive only while the reader is editing.
    ///
    /// **Here rather than on `AppModel`.** Every keystroke in the bio changes
    /// it, and on the shared store that would invalidate every view in the
    /// window; it also has exactly the lifetime of this presentation, so a
    /// store-held copy is one more thing that has to be remembered to clear.
    @State private var editor: ProfileEditor?
    /// The one sheet left in the editor — adding a connection, a sign-in.
    @State private var picker: ProfileEditPicker?
    /// Which flyout is up — see `ProfileFlyouts`. One for the presenter's
    /// lifetime; closed whenever the profile changes.
    @State private var flyouts = ProfileFlyouts()

    /// The card's own width, shared by the card and by the arithmetic that
    /// places it. Two copies is how a card ends up anchored eight points from
    /// where it is drawn.
    private static let cardWidth: CGFloat = 320
    /// The full profile's ceiling, and the air left around it.
    ///
    /// **The board decides this width, not the sheet.** An application widget is
    /// the widest thing a profile draws — hero artwork over a three-column stat
    /// grid — and it stretches to whatever column it is handed. Measured off
    /// Discord's profile and this one captured on the same screen: their widget
    /// card is 432 points and ours was 636, which is what turned the header into
    /// a letterbox with the character standing alone at the far end and printed
    /// "Valley IV Regional Development Level" on one line where Discord wraps it
    /// onto two. So the column is sized to the card and the sheet follows from
    /// it, rather than the card being handed whatever is left over.
    private static let maximumWidth: CGFloat =
        ProfileIdentityPanel.width + ProfileSheet.contentWidth
    private static let maximumHeight: CGFloat = 780
    private static let inset: CGFloat = 48

    func body(content: Content) -> some View {
        content.overlay {
            // Reads the root's size for the placement to clamp against. A
            // reader, not a stored measurement: the value is consumed in the
            // same pass that produces it and never written to `@State`, so
            // there is no extra layout pass and nothing that can outlive what
            // it measured.
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    if let request = model.profileRequest,
                       let profile = model.profilePresentation(for: request) {
                        dismissLayer(dimmed: request.depth == .full)
                        surface(request, profile, container: proxy.size)
                    }
                }
                // Declared by the container that should animate, never by the
                // writer — a `withAnimation` on a store property the whole
                // window observes opens a global transaction and animates every
                // view that happens to re-lay-out while it runs.
                .animation(motion.panel, value: model.profileRequest)
                // **Torn down with the profile it belongs to.** A draft that
                // survived the sheet closing would be applied to whoever was
                // opened next — and the id changes for a new subject as well as
                // for none at all, so both cases land here.
                .onChange(of: model.profileRequest?.id) {
                    picker = nil
                    flyouts.close()
                    // **Seeded rather than merely cleared**, for the one caller
                    // that asks to arrive editing — the server menu's Edit
                    // Per-server Profile, which has a server in hand and a page
                    // to land on. Every other request clears it.
                    editor = editorForRequest()
                }
                .task(id: model.profileRequest?.id) {
                    // The first request of a session arrives before that
                    // `onChange` has anything to compare against.
                    if editor == nil { editor = editorForRequest() }
                }
            }
        }
    }

    /// Outside-click and Escape, as one control.
    ///
    /// A `Button` rather than a tap gesture on a shape: a button is what
    /// `.keyboardShortcut` attaches to, it is what VoiceOver can find and
    /// describe, and it makes the two ways out of this card the same object
    /// rather than two that can disagree.
    private func dismissLayer(dimmed: Bool) -> some View {
        Button(action: requestClose) {
            // **A scrim under the full profile, nothing under the card.** A
            // modal task dims what it interrupts; a card beside a row does not
            // interrupt anything, and dimming the transcript behind it would
            // say it did.
            (dimmed ? Color.black.opacity(0.45) : Color.clear)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .cancelAction(unless: model.isCovered(.profile))
        .accessibilityLabel(Text("Close profile"))
        // **Past the titlebar, or the scrim stops at the toolbar's foot.** The
        // window is `fullSizeContentView` and this overlay is laid out inside
        // its safe area, so without this the chrome strip — the channel name,
        // the search field, the reader's own banner behind them — stayed at full
        // brightness over a dimmed window, which reads as the toolbar belonging
        // to something else. The same call the quick switcher's scrim makes.
        .ignoresSafeArea()
        .transition(.opacity)
    }

    @ViewBuilder
    private func surface(
        _ request: ProfileRequest,
        _ profile: ProfilePresentation,
        container: CGSize
    ) -> some View {
        switch request.depth {
        case .mini:
            miniCard(request, profile, container: container)
        case .full:
            ProfileSheet(
                profile: profile,
                board: model.boardPresentation(for: request.userID),
                activity: model.activityPresentation(for: request.userID),
                // **A ceiling, not a size.** The sheet takes this width and as
                // much of this height as its content actually needs — an
                // account with a bio and nothing else is a short sheet rather
                // than four hundred points of void under a name.
                // **The rail is added to the ceiling, not taken out of it.**
                // Discord's own modal grows by exactly its rail's width when the
                // editor opens — 961 points to 1,195 — because the profile has
                // to stay whole beside the controls that change it.
                maximumSize: CGSize(
                    width: min(
                        container.width - Self.inset * 2,
                        Self.maximumWidth + (editor == nil ? 0 : ProfileEditRail.width)
                    ),
                    height: min(container.height - Self.inset * 2, Self.maximumHeight)
                ),
                editor: editor,
                beginEditing: { editor = makeEditor(.account, for: profile.userID) },
                endEditing: {
                    // The rail's chevron is a way out too — and the same rule.
                    if let editor, editor.isDirty { editor.nudge() } else { editor = nil }
                },
                scopes: editor == nil ? [] : model.profileEditScopes(for: profile.userID),
                selectScope: { switchScope(to: $0.scope, for: profile.userID) },
                saveEdits: { commit(profile) },
                // Only the connection sheet is raised by closure; every
                // cosmetic is a flyout hung off its own control.
                presentPicker: { raised in
                    if raised == .connection { picker = raised } else { flyouts.show(raised, from: .rail) }
                },
                dismiss: requestClose,
                initialTab: request.tab
            )
            // **Keyed on the one value that can change under the draft**, not on
            // the whole presentation: resolving a profile per body evaluation to
            // compare it would be a presentation build on every hover.
            .onChange(of: editorLayer) { refreshEditorIfUntouched() }
            .environment(flyouts)
            .environment(editor)
            .modal(item: $picker) { picker in
                if picker == .connection {
                    AddConnectionSheet(dismiss: { self.picker = nil })
                }
            }
            // Add App, over the app's profile — Discord's authorize modal over
            // its own. Its own value, not the directory's, so discovery's sheet
            // and this one can never both be asked for at once.
            .modal(item: Binding(
                get: { model.profileApplicationInstall },
                set: { model.profileApplicationInstall = $0 }
            )) { install in
                AddApplicationSheet(request: install, channelID: model.selectedChannelID) {
                    model.profileApplicationInstall = nil
                }
                .environment(model)
            }
            // **And then given the whole container to sit in.** The layer's
            // stack is top-leading aligned, so a sized child without this is
            // pinned to the window's corner — which is where the stage was
            // sitting, an 1,080-point sheet jammed against the top-left edge.
            .frame(width: container.width, height: container.height)
            .transition(.materialize)
        }
    }

    /// Closes the profile — **unless an edit is unsaved**, which Discord
    /// refuses with "Careful — you have unsaved changes!" and so does this:
    /// the save bar shakes, and the draft stays.
    private func requestClose() {
        if let editor, editor.isDirty {
            editor.nudge()
            return
        }
        model.profileRequest = nil
    }

    /// Writes the draft, and reloads the profile from Discord rather than
    /// trusting the reply.
    ///
    /// **The reload is not belt and braces.** The save fans out over up to four
    /// routes and each answers only for its own fields, so the only thing that
    /// knows what the profile is afterwards is the profile route. A surface that
    /// patched its own state from four partial replies would drift from the
    /// truth in exactly the cases the reader cannot see.
    private func commit(_ profile: ProfilePresentation) {
        guard let editor else { return }
        // `--demo` makes no requests: the draft lands on the fixture instead.
        if LaunchOptions.current.usesDemoFixtures {
            model.applyDemoProfileEdit(editor)
            self.editor = nil
            return
        }
        Task {
            if await editor.save(using: model.sessionController.rest) {
                self.editor = nil
                // The member the server answered with, filed now — the roster
                // and the transcript read the new nickname and face from it.
                if let member = editor.savedMember, let guildID = editor.scope.guildID {
                    model.members[guildID, default: [:]][member.userID] = member
                }
                // Nothing echoes the account's own indicator back, so the
                // draft that just landed is the truth until the next READY.
                if editor.scope == .account {
                    model.ownTypingIndicatorStyle = editor.typingIndicatorStyle
                }
                // **The scope that was written**, not the one the rail happens
                // to be pointing at: a server edit saved from a DM has to
                // refetch that server's layer or the card shows the old one.
                model.sessionController.loadProfile(
                    of: profile.userID,
                    inGuild: editor.scope.guildID ?? model.selectedGuildID
                )
            }
        }
    }

    /// The server layer the open draft was seeded from, or nil for the account
    /// scope — the thing whose arrival should re-seed an untouched draft.
    private var editorLayer: User? {
        guard let editor, let guildID = editor.scope.guildID else { return nil }
        return model.memberProfiles[guildID]?[editor.userID]
    }

    /// The draft an incoming request asks for, or nil for one that does not.
    private func editorForRequest() -> ProfileEditor? {
        guard let request = model.profileRequest, let scope = request.editsScope else {
            return nil
        }
        return makeEditor(scope, for: request.userID)
    }

    /// A draft at `scope`, seeded from that scope's own profile.
    ///
    /// **A server scope asks for its layer as it opens.** Only
    /// `GET /users/{id}/profile?guild_id=…` answers with a per-server bio,
    /// banner or pronouns, and a server the reader has never opened a profile
    /// in has never been asked — so without this the draft starts from the
    /// account's values and a Save would copy them onto the server.
    private func makeEditor(_ scope: ProfileEditor.Scope, for userID: UserID) -> ProfileEditor? {
        guard let base = model.profileEditBase(for: scope, userID: userID) else { return nil }
        if let guildID = scope.guildID {
            model.sessionController.loadProfile(of: userID, inGuild: guildID)
        }
        let editor = ProfileEditor(
            profile: base,
            // The raw board, which is what the write route takes —
            // `boardPresentation` has already resolved it into tiles and
            // dropped the ids.
            widgets: model.profileWidgets[userID] ?? [],
            scope: scope,
            accountName: model.users[userID]?.preferredName,
            typingIndicatorStyle: model.ownTypingIndicatorStyle
        )
        editor.appliesNameStyle = model.profileEditCapability(for: scope).canApplyNameStyle
        return editor
    }

    /// Moves the editor to another profile.
    ///
    /// **Refused while there are unsaved changes** — Discord's own rule, and
    /// the only safe one: a draft belongs to one scope, and carrying it across
    /// would write a server's nickname as an account name, or throw five edits
    /// away on a mis-click. The switcher disables itself in the same state, so
    /// this guard is the second line rather than the first.
    private func switchScope(to scope: ProfileEditor.Scope, for userID: UserID) {
        guard let editor, editor.scope != scope, !editor.isDirty else { return }
        self.editor = makeEditor(scope, for: userID)
    }

    /// Re-seeds an untouched draft when its scope's profile changes under it —
    /// which is what happens when the server layer `makeEditor` asked for
    /// arrives a moment after the rail switched.
    ///
    /// **Never over an edit.** A dirty draft is the reader's, and a network
    /// answer arriving is no reason to discard what they typed.
    private func refreshEditorIfUntouched() {
        guard let editor, !editor.isDirty,
              let base = model.profileEditBase(for: editor.scope, userID: editor.userID),
              base != editor.base
        else { return }
        self.editor = makeEditor(editor.scope, for: editor.userID)
    }

    private func miniCard(
        _ request: ProfileRequest,
        _ profile: ProfilePresentation,
        container: CGSize
    ) -> some View {
        let overhang = profile.frame?.overhang(cardWidth: Self.cardWidth) ?? EdgeInsets()
        let placement = ProfileCardPlacement(
            anchor: request.anchor,
            cardWidth: Self.cardWidth,
            overhang: overhang,
            container: container,
            // The now bar is pinned to the window's foot and its card has to
            // rise out of it — see `ProfileCardPlacement.Side`. Every other
            // caller is a row in a column.
            side: request.showsOwnActions ? .above : .beside
        )
        return MiniProfileCard(
            profile: profile,
            openFullProfile: { tab in
                // Set the new depth synchronously. Deferring a presentation by
                // a timer to let the first one go is a race that gets lost: the
                // flag lives on the store while the code setting it runs inside
                // a view being torn down, and a missed window drops the request
                // silently.
                model.expandProfile(tab: tab)
            },
            openLink: { model.openLink($0) },
            widgetPreviews: model.widgetPreviews(for: request.userID),
            width: Self.cardWidth,
            // The window's height less the placement's margins and the frame's
            // overhang — past it the card scrolls rather than leaving the window.
            maxHeight: max(
                0,
                container.height - 2 * ProfileCardPlacement.margin - overhang.top - overhang.bottom
            ),
            // Only where the caller asked for them — see
            // `ProfileRequest.showsOwnActions`. Opening your own card from a
            // transcript is opening it to read.
            ownActions: request.showsOwnActions
                ? model.ownProfileActions(startsOn: request.ownSurface, dismiss: { model.profileRequest = nil })
                : nil
        )
        // **Placed by alignment guides, not by `.position` or by a measured
        // `@State`.** The card's height is its content's — a bio and a role flow
        // that arrive over the network — and a guide is handed that height
        // *during* the layout pass that consumes it. Measuring it into state
        // instead would cost an extra pass, invalidate everything downstream,
        // and leave a number that outlives the card.
        //
        // Both guides subtract the overhang, because what they position is the
        // padded box while what the placement solves for is the card. Anchoring
        // the padded box instead would shove the card sideways by the artwork's
        // width the moment a frame resolved.
        .alignmentGuide(.leading) { _ in
            -(placement.cardX - overhang.leading)
        }
        .alignmentGuide(.top) { dimensions in
            let cardHeight = dimensions.height - overhang.top - overhang.bottom
            return -(placement.cardY(forHeight: cardHeight) - overhang.top)
        }
        // Grown from the corner nearest the row that opened it.
        .transition(.materialize(from: placement.growthAnchor))
    }
}

extension View {
    /// Apply once, at the window root.
    func presentsProfiles() -> some View {
        modifier(ProfilePresenter())
    }
}

extension View {
    /// Escape, but only while this really is the topmost layer.
    ///
    /// **Several controls in this app claim `.cancelAction` at once**, and one
    /// key cannot mean several things: the profile's scrim, the profile sheet's
    /// own close button, the game profile's scrim above both, and the tenure
    /// badge's page above that. SwiftUI settles a contested shortcut by
    /// hierarchy rather than by what is drawn on top, so Escape over an open
    /// game profile closed the profile *underneath* it and left the page
    /// floating over nothing.
    ///
    /// The quick switcher covers all of them — it is opened by a key rather
    /// than by a click, so it is the one layer that can appear over any of the
    /// others without anybody having dismissed anything. Its own field handles
    /// Escape while it has focus, but a key *equivalent* is matched before a key
    /// press reaches the responder chain, so the layers underneath have to give
    /// the shortcut up rather than rely on that.
    ///
    /// **Ask `AppModel.escapeLayer` rather than listing what might be on top.**
    /// Every caller spelling out its own exclusions is how a layer added later
    /// gets left out of four predicates at once — which is exactly what happened
    /// to the tenure page, whose Escape closed the profile behind it.
    ///
    /// A conditional `KeyboardShortcut?` rather than `.disabled`: a disabled
    /// control gives up its shortcut but also stops answering the pointer and
    /// takes its label's contrast with it, which is wrong for a button that is
    /// merely covered rather than unavailable.
    func cancelAction(unless isCovered: Bool) -> some View {
        keyboardShortcut(isCovered ? nil : .cancelAction)
    }
}

extension AppModel {
    /// The floating layers that answer Escape, **in the order they stack**.
    ///
    /// One list rather than a predicate at each call site: the order is a fact
    /// about the app and belongs somewhere a new layer has to be inserted into,
    /// not repeated in every control that might be under it.
    enum EscapeLayer: Equatable {
        /// The call, full screen — under every layer, because it is applied
        /// before all of them and everything a tile raises comes up over it.
        case callFullScreen
        /// Bottom of the group: `.presentsMedia()` is applied first at the
        /// window root, and an earlier `.overlay` draws under a later one.
        case mediaViewer
        /// Drawn by `.presentsMessageActions()`, applied after the media
        /// viewer and before the profiles — so a profile opened from a row in
        /// it comes up on top.
        case reactions
        /// A server's events — drawn by the message actions' presenter after
        /// the reactors list, so a profile opened from somebody interested
        /// comes up above it.
        case events
        /// A form an application raised — drawn by the same presenter, after
        /// the reactors list.
        case interactionModal
        /// The holders of a role, beside its mention — drawn by the message
        /// actions' presenter, under the profiles, so a card a row opens is
        /// above it.
        case roleMembers
        /// An Activity card's popout, beside the member list — under the
        /// profiles, so a face clicked in it opens above it.
        case activityCard
        case profile
        case gameProfile
        case tenureBadge
        /// Share Your Screen — drawn by `.presentsVoiceSurfaces()`, after every
        /// layer a message or a profile raises and under the quick switcher.
        case goLive
        case quickSwitcher
        /// One of the window's cards — a sheet, an alert, a dialog — drawn by
        /// `.hostsModals()`, applied after every presenter: whatever raised it
        /// is under it, the quick switcher included.
        case modal
    }

    /// Which of them is on top right now, or nil when none is open.
    var escapeLayer: EscapeLayer? {
        if isModalShown { return .modal }
        if isQuickSwitchShown { return .quickSwitcher }
        if isGoLiveSheetOpen { return .goLive }
        if tenureBadgeRequest != nil { return .tenureBadge }
        if gameProfileRequest != nil { return .gameProfile }
        if profileRequest != nil { return .profile }
        if activityCardRequest != nil { return .activityCard }
        if roleMembersRequest != nil { return .roleMembers }
        if interactionModal != nil { return .interactionModal }
        if eventsPanel != nil { return .events }
        if reactionsList != nil { return .reactions }
        if mediaViewer != nil { return .mediaViewer }
        if isCallFullScreen { return .callFullScreen }
        return nil
    }

    /// Whether a floating layer is drawn over the window's content.
    ///
    /// **The drawn canvases need this and cannot work it out.** An
    /// `NSTrackingArea` reports the pointer from its own rect in window space;
    /// AppKit does not occlusion-test it against whatever is drawn on top, so a
    /// SwiftUI layer over the transcript takes every *click* — `hitTest:` does
    /// respect view order — and none of the moves. The transcript therefore kept
    /// lighting rows, playing avatars and raising its hover action bar
    /// underneath an open profile, which is where the reader saw it: a pill
    /// sticking out from behind the card.
    ///
    /// Derived from `escapeLayer` rather than kept as a second list. Two lists
    /// of "what is on top" is how the next layer added gets into one of them.
    /// **The media viewer too**: it answers Escape itself rather than through
    /// an escape layer, so the transcript under it went on setting its I-beam
    /// and pointing hand over the viewer's controls (Alex, 2026-11-17).
    var isWindowCovered: Bool { escapeLayer != nil || mediaViewer != nil }

    /// Whether `layer` is covered by something above it.
    ///
    /// **Not `escapeLayer != layer`**: a layer that is not open at all is also
    /// not the top one, and answering "covered" for it would take the shortcut
    /// away from a control that is about to want it — the profile sheet's close
    /// button asks this while the sheet is being presented.
    func isCovered(_ layer: EscapeLayer) -> Bool {
        guard let escapeLayer else { return false }
        return escapeLayer != layer
    }
}
