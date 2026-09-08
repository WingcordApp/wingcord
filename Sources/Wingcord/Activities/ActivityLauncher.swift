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

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @Environment(\.dismiss) private var dismiss

    /// The debounce. A keystroke per request would send five for "wordl".
    @State private var searchTask: Task<Void, Never>?

    static let width = ExpressionPicker.width
    static let height: CGFloat = 468

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
        .frame(width: Self.width, height: Self.height)
        // **A sheet, not a third page.** Adding an app grants something, and a
        // grant that shares its surface with a back button is a grant somebody
        // dismisses by reflex. It also has to survive the flyout closing behind
        // it, which a page inside the flyout cannot.
        .sheet(item: $model.applicationInstallRequest) { request in
            AddApplicationSheet(
                request: request,
                channelID: channelID,
                onFinished: { model.applicationInstall = nil }
            )
            .environment(model)
        }
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
        let sections = model.activitySections
        if sections.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Spacing.group, pinnedViews: []) {
                    ForEach(sections) { section in
                        ActivitySectionView(section: section, onOpen: open(_:))
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
    private static let barInset = Metrics.control + Spacing.base * 2

    private var searchBar: some View {
        @Bindable var model = model
        return HStack(spacing: Spacing.base) {
            Image(systemName: "magnifyingglass")
                .font(.system(.subheadline))
                .foregroundStyle(Ink.tertiary)

            TextField("Search apps", text: $model.activityQuery)
                .textFieldStyle(.plain)
                .font(.system(.subheadline))
                .onChange(of: model.activityQuery, search)

            if !model.activityQuery.isEmpty {
                Button { model.activityQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(.subheadline))
                        .foregroundStyle(Ink.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, Spacing.snug)
        .frame(minHeight: Metrics.control)
        .chromeOverMedia()
        .padding(.horizontal, Spacing.snug)
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

    private var emptyState: some View {
        VStack(spacing: Spacing.base) {
            Spacer()
            Image(systemName: model.activityQuery.isEmpty ? "square.grid.2x2" : "magnifyingglass")
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
