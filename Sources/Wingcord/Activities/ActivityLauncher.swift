import SwiftUI
import WingcordCore

/// The launcher — Recents, the featured row, and the directory's nine
/// collections, with search over all of it.
///
/// **The same panel geometry as the expression picker, deliberately.** Both
/// open from the same cluster of composer controls, and two flyouts of
/// different widths opening a few points apart read as two unrelated things
/// rather than as one set of tools. `ExpressionPicker.width` is the shared
/// number; the height is taller because a directory row is three times an
/// emoji cell.
///
/// **Everything floats and the content runs underneath.** The search bar is a
/// glass bar the artwork passes beneath, exactly as the picker's is — and for
/// the same reason it takes **`.clear`, never `.regular`**: what scrolls under
/// it is game artwork, and `.regular` over media is frost that blurs the
/// content away instead of lensing it. `INVARIANTS.md` §4.
///
/// **Two pages, not a navigation stack.** There is exactly one place to go from
/// here — an app's own page — and one way back. A `NavigationStack` inside a
/// popover buys a chrome bar this design does not draw and a transition it
/// animates itself.
struct ActivityLauncher: View {
    var channelID: ChannelID
    /// The composer's Apps button or a call's Activities button (decision 5).
    var context: ActivityLauncherContext = .composer

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @ModalDismiss private var dismiss

    /// The debounce. A keystroke per request would send five for "wordl".
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var isSearchFocused: Bool


    /// How long a keystroke waits before it becomes a request. Short enough to
    /// feel like typing, long enough that a five-letter word is one call.
    private static let searchDebounce = Duration.milliseconds(220)

    var body: some View {
        @Bindable var model = model
        return Group {
            switch model.activityLauncherPage {
            case .directory:
                directory
                    .transition(.opacity)
            case .app(let id):
                ActivityDetailPage(
                    applicationID: id,
                    channelID: channelID,
                    flyoutWidth: context.size.width,
                    onBack: { model.activityLauncherPage = .directory },
                    onLaunched: { dismiss() },
                    // A command with options goes to the composer rather than
                    // being filled in here: `gen eject` wants a person, and a
                    // people picker does not belong in a 388-point page that is
                    // already scrolling. The bar it lands in is the one the `/`
                    // list already fills.
                    onOpenStore: {
                        model.activityLauncherPage = .store(
                            id,
                            name: model.activityApp(id)?.name ?? ""
                        )
                    },
                    onFillCommand: { command in
                        model.mutateBox(channelID) { box in
                            box.draft = ""
                            box.command = PendingCommand(command: command)
                        }
                    },
                    // **The flyout has somewhere to go after all.** These rows
                    // were drawn with no handler passed, so "You might also
                    // like" was three controls that did nothing — §5.5 — while
                    // the page they lead to is the one this view already shows.
                    onOpenSimilar: { model.activityLauncherPage = .app($0) }
                )
                .transition(.opacity)

            case .store(let id, let name):
                ApplicationStorePage(
                    applicationID: id,
                    name: name,
                    onBack: { model.activityLauncherPage = .app(id) }
                )
                .transition(.opacity)
            }
        }
        .frame(width: context.size.width, height: context.size.height)
        // No background: the popover's own material IS the panel, and painting
        // over it is what turns liquid glass into a flat dark rectangle.
        .animation(motion.fade, value: model.activityLauncherPage)
        .task {
            // Both are guarded against a second run, so this costs nothing on
            // the second open. Sequential rather than concurrent: Recents
            // resolves ids *against* the directory, and running them together
            // would send a `/applications/public` call for rows the shelf was
            // about to describe anyway.
            await model.sessionController.loadActivityDirectory()
            await model.sessionController.loadActivityRecents()
        }
        .onDisappear {
            searchTask?.cancel()
            // The page is reset on close, not on open: reopening onto the app
            // page you were reading a second ago is the surprise, and a reset
            // at open would flash the directory over it first.
            model.activityLauncherPage = .directory
            model.activityQuery = ""
        }
    }

    // MARK: The directory

    private var directory: some View {
        ZStack(alignment: .top) {
            content
            searchBar
        }
    }

    @ViewBuilder
    private var content: some View {
        let sections = model.activitySections(for: context)
        let running = model.activityQuery.isEmpty ? model.runningActivities(in: channelID) : []
        if sections.isEmpty, running.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Spacing.group + Spacing.base, pinnedViews: []) {
                    if !running.isEmpty { runningSection(running) }
                    ForEach(sections) { section in
                        ActivitySectionView(
                            section: section,
                            onOpen: open(_:),
                            onStart: cardStart
                        )
                    }
                }
                .padding(.horizontal, Spacing.snug)
                .padding(.bottom, Spacing.margin)
                // The bar floats over the content, so the first row has to
                // start below it or it opens hidden.
                .padding(.top, Self.barInset)
            }
            .scrollIndicators(.never)
            .softScrollEdgesVertical()
        }
    }

    /// The bar's own height plus the margins around it. A measured value would
    /// be better — and the picker measures its own, because its chrome has a
    /// rail whose height depends on the account. This bar is one control of a
    /// fixed size, so the sum cannot drift.
    private static let searchHeight: CGFloat = 40
    private static let searchCorner: CGFloat = 12
    private static let barInset = searchHeight + Spacing.base * 2 + Spacing.tight

    /// **Bigger, frosted, and a field rather than a lens** (Alex, 2026-11-18:
    /// "making the search bar bigger and less refractive"). It was clear
    /// glass, which lenses the artwork scrolling under it — right for a
    /// toolbar, hard to read and type into. The large search field's height,
    /// on the regular material with a hairline, reads as a place to type and
    /// stays legible over any cover; the accent rings it while it has focus.
    private var searchBar: some View {
        @Bindable var model = model
        return HStack(spacing: Spacing.base) {
            Image(systemName: "magnifyingglass")
                .font(.system(.body, weight: .medium))
                .foregroundStyle(isSearchFocused ? Palette.accent : Ink.secondary)

            TextField("Search apps & activities", text: $model.activityQuery)
                .textFieldStyle(.plain)
                .font(.body)
                .focused($isSearchFocused)
                .onChange(of: model.activityQuery, search)

            if !model.activityQuery.isEmpty {
                Button { model.activityQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(.body))
                        .foregroundStyle(Ink.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .padding(.horizontal, Spacing.snug + Spacing.hair)
        .frame(height: Self.searchHeight)
        .background(.regularMaterial, in: .rect(cornerRadius: Self.searchCorner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Self.searchCorner, style: .continuous)
                .strokeBorder(
                    isSearchFocused ? Palette.accent.opacity(0.75) : Palette.edge,
                    lineWidth: isSearchFocused ? 1.5 : 1
                )
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.2), radius: 12, y: 5)
        .animation(motion.hover, value: isSearchFocused)
        .animation(motion.hover, value: model.activityQuery.isEmpty)
        .padding(.leading, Spacing.snug)
        .padding(.trailing, context == .call ? Metrics.control + Spacing.snug * 2 : Spacing.snug)
        .overlay(alignment: .trailing) {
            // The card's own close beside the field (a `.panel` card's round ✕).
            if context == .call {
                ModalCloseButton { dismiss() }
                    .padding(.trailing, Spacing.snug)
            }
        }
        .padding(.top, Spacing.base)
    }

    private func search() {
        searchTask?.cancel()
        let query = model.activityQuery
        searchTask = Task {
            try? await Task.sleep(for: Self.searchDebounce)
            guard !Task.isCancelled else { return }
            await model.sessionController.searchActivities(query)
        }
    }

    private func open(_ row: ActivityRow) {
        model.activityLauncherPage = .app(row.id)
    }

    /// What a card's own button does here: start the app in the call, or
    /// nothing in the composer, where a card opens the app's page.
    private var cardStart: ((ActivityRow) -> Void)? {
        guard context.startsFromCards else { return nil }
        return { start($0) }
    }

    /// Starts a game in the call from its card: joins the one already running
    /// here, launches it otherwise (decision 2).
    private func start(_ row: ActivityRow) {
        guard let app = model.activityApp(row.id) else { return open(row) }
        dismiss()
        Task { await model.sessionController.startActivity(app, in: channelID, section: "activity_shelf") }
    }

    /// What's already running here, first: Join beats Launch (decision 5).
    private func runningSection(_ running: [CallActivityPresentation]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            Text(model.isCallBandShowing(in: channelID) || context == .call ? "In This Call" : "Playing Now")
                .font(Typeface.sectionHeader)
                .foregroundStyle(Ink.secondary)
                .textCase(.uppercase)
                .kerning(0.4)
                .padding(.leading, Spacing.tight)
            ForEach(running) { activity in
                ActivityRunningCard(
                    activity: activity,
                    onJoin: {
                        dismiss()
                        model.joinCallActivity(activity)
                    },
                    onReturn: {
                        dismiss()
                        model.returnToActivity()
                    }
                )
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.base) {
            Spacer()
            Image(symbol: model.activityQuery.isEmpty ? "square.grid.2x2" : "magnifyingglass")
                .font(.system(size: 26))
                .foregroundStyle(Ink.quaternary)
            Text(emptyMessage)
                .font(.system(.subheadline))
                .foregroundStyle(Ink.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(.horizontal, Spacing.group)
        .frame(maxWidth: .infinity)
    }

    private var emptyMessage: String {
        if !model.activityQuery.isEmpty {
            return "No apps match “\(model.activityQuery)”"
        }
        // The directory failing to load and the directory being empty are the
        // same picture, and only one of them is worth a retry — so the words
        // say which one this is rather than asserting there is nothing.
        return model.activityDirectory.isEmpty
            ? "Apps could not be loaded"
            : "No apps here yet"
    }
}
