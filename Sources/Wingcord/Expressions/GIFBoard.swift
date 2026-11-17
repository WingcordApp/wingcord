import SwiftUI
import WingcordCore

/// The GIF tab: a landing grid of categories, and one list of results reached
/// by opening a tile or by searching.
///
/// **Two screens, not one.** A single screen means a sideways scrub to reach any
/// category, and it leans on a trending payload that has come back with as
/// little as one item — so the tab opens on a lone grey square under a row you
/// have to drag to read. Trending is a tile like any other here, which leaves
/// the landing with nothing to be empty.
///
/// **Not a canvas, unlike the other two tabs.** A page is fifty items of varying
/// aspect ratio that have to animate; the uniform-cell arithmetic the grid
/// canvas is built on does not describe it, and fifty cells is not the density
/// that made drawing worth it.
struct GIFBoard: View {
    @Binding var query: String
    /// Whether the reader's favourites lead the landing. Discord's Choose GIF
    /// for an avatar or a banner leaves them out (`hideFavorites`).
    var showsFavorites = true
    /// False inside the expression picker, whose header row has the one
    /// search field for every tab (decision 12).
    var showsSearchField = true
    /// Room for chrome floating over the board from outside it.
    var topInset: CGFloat = 0
    var onPick: (GIF) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion
    @State private var store = GIFStore()

    /// What the floating chrome takes, so the content can be inset by it and
    /// pass underneath. The back header only exists inside a scope.
    private var chromeHeight: CGFloat {
        let header = store.scope == nil ? 0 : Metrics.control + Spacing.base
        let field = showsSearchField ? Metrics.control + Spacing.base : 0
        return topInset + Spacing.base + header + field
    }

    var body: some View {
        ZStack(alignment: .top) {
            body(for: store.scope)
                .safeAreaPadding(.top, chromeHeight)

            // One assembly, one material — see `ExpressionPicker.chrome`.
            GlassEffectContainer(spacing: Spacing.base) {
                VStack(spacing: Spacing.base) {
                    if let scope = store.scope { scopeHeader(scope) }
                    if showsSearchField { searchField }
                }
                .padding(.horizontal, Spacing.snug)
                .padding(.top, Spacing.base + topInset)
            }
        }
        .task {
            store.session = model.sessionController
            // Sequential: the landing grid is what the board draws first, and
            // the favourites come out of the settings blob the apps flyout may
            // already have fetched.
            await store.loadLanding()
            await model.sessionController.loadFavoriteGIFs()
        }
        .task(id: query) {
            // Debounced: a request per keystroke otherwise, and Discord rate
            // limits this route hard.
            guard !query.isEmpty else {
                store.searchCleared()
                return
            }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await store.search(query)
        }
    }

    @ViewBuilder
    private func body(for scope: GIFScope?) -> some View {
        if scope == nil {
            if store.categories.isEmpty && store.isLoading {
                loading
            } else if store.categories.isEmpty {
                message("GIFs are unavailable right now")
            } else {
                landing
            }
        } else if !store.results.isEmpty {
            results
        } else if store.isLoading {
            loading
        } else {
            message("No GIFs here")
        }
    }

    // MARK: Landing

    private var landing: some View {
        ScrollView {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: Spacing.base),
                    GridItem(.flexible(), spacing: Spacing.base),
                ],
                spacing: Spacing.base
            ) {
                // Favourites first when there are any — it is the only tile
                // whose contents the reader put there themselves. Absent rather
                // than empty: a tile that opens onto nothing is worse than no
                // tile, which is the same rule the rail follows.
                if showsFavorites, !model.favoriteGIFs.isEmpty {
                    tile(
                        title: "Favorites",
                        icon: "star.fill",
                        // A picture: this tile's art is decoded, not played.
                        art: model.favoriteGIFs.first { !$0.isVideo }?.previewURL
                    ) { store.openFavorites(model.favoriteGIFs) }
                }
                tile(
                    title: "Trending GIFs",
                    icon: "chart.line.uptrend.xyaxis",
                    art: store.trendingSeed.first?.previewURL
                ) { await store.openTrending() }

                ForEach(store.categories) { category in
                    tile(title: category.name, icon: nil, art: category.previewURL, video: category.videoURL) {
                        await store.open(category: category.name)
                    }
                }
            }
            .padding(.horizontal, Spacing.snug)
            .padding(.bottom, Spacing.base)
        }
        .scrollIndicators(.never)
        .scrollClipDisabled()
    }

    /// One category. Cover art, a scrim, and the name over it.
    ///
    /// **The art is still, not animated.** An animated tile holds every decoded
    /// frame of its asset, and a screenful of half-width tiles is a much larger
    /// asset than a result thumbnail. Results animate; the menu that leads to
    /// them does not.
    private func tile(
        title: String,
        icon: String?,
        art: URL?,
        video: URL? = nil,
        open: @escaping () async -> Void
    ) -> some View {
        Button {
            Task { await open() }
        } label: {
            Color.clear
                .aspectRatio(2.2, contentMode: .fit)
                .overlay {
                    RemoteImage(url: art, side: 200, bucket: .attachment) {
                        Rectangle().fill(Palette.surfaceRaised)
                    }
                    .aspectRatio(contentMode: .fill)
                }
                .overlay {
                    // A video preview plays (hardware, lazily); without one the
                    // tile stays a still: decoding every category's GIF into
                    // frames at once was a main-thread stall on open.
                    if let video {
                        LoopingVideo(url: video, isPlaying: !motion.reduceMotion)
                    }
                }
                .overlay {
                    // The label has to stay readable over a frame whose
                    // brightness the tile does not get to choose.
                    Rectangle().fill(.black.opacity(0.4))
                }
                .overlay {
                    HStack(spacing: Spacing.tight) {
                        if let icon {
                            Image(symbol: icon)
                                .font(.system(.caption, weight: .semibold))
                        }
                        Text(title)
                            .font(.system(.subheadline, weight: .semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, Spacing.base)
                }
                .clipShape(.rect(cornerRadius: Radius.chip, style: .continuous))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
    }

    // MARK: Results

    private var results: some View {
        ScrollView {
            masonry.padding(.bottom, Spacing.base)
        }
        .scrollIndicators(.never)
        .scrollClipDisabled()
    }

    /// Two columns filled by running height rather than by alternating index.
    ///
    /// Alternating leaves one column visibly longer the moment the aspect ratios
    /// differ, which for GIFs they always do.
    private var masonry: some View {
        let columns = Self.split(store.results, into: 2)
        return HStack(alignment: .top, spacing: Spacing.base) {
            ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                LazyVStack(spacing: Spacing.base) {
                    ForEach(column) { gif in
                        Button { onPick(gif) } label: {
                            tile(gif)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("GIF")
                    }
                }
            }
        }
        .padding(.horizontal, Spacing.snug)
    }

    /// One result: the still first, the film over it.
    ///
    /// **Stacked, not swapped.** The two are decoded by different paths at
    /// different moments, and the still is what stops a wall of grey rectangles
    /// while the filmstrips arrive — `AnimatedDecoration` draws nothing until it
    /// has frames, so the picture underneath simply shows through.
    private func tile(_ gif: GIF) -> some View {
        Color.clear
            .aspectRatio(gif.aspectRatio, contentMode: .fit)
            .overlay {
                if let video = gif.videoURL {
                    // **Video, not frames** (decision 14): the MP4 plays,
                    // hardware-decoded, over its still, and only while the tile
                    // is on screen (the column is lazy). No decode of a
                    // hundred GIF frames per tile on the main thread, which is
                    // what stalled the picker in issue #23.
                    RemoteImage(url: gif.previewURL, side: Self.tileSide, bucket: .attachment) {
                        Rectangle().fill(Palette.surfaceRaised)
                    }
                    .overlay { LoopingVideo(url: video, isPlaying: !motion.reduceMotion) }
                } else if gif.isVideo, let url = gif.previewURL {
                    // **A video favourite plays, as Discord's picker plays it.**
                    // Its rendition is Tenor's MP4, which the image path below
                    // decodes nothing from — the tile stayed a plate for good.
                    Rectangle().fill(Palette.surfaceRaised)
                        .overlay { LoopingVideo(url: url, isPlaying: !motion.reduceMotion) }
                } else {
                    RemoteImage(url: gif.previewURL, side: Self.tileSide, bucket: .attachment) {
                        Rectangle().fill(Palette.surfaceRaised)
                    }
                }
            }
            .overlay {
                // **No `CDN.canAnimate` gate here, and that was the bug.** That
                // test reads the path extension, which is a complete answer only
                // for URLs Discord's CDN built — where the extension came from
                // the hash's own `a_` prefix. A GIF provider's URL carries no
                // such promise: the ones with `.gif` animated and the ones
                // without silently got no filmstrip at all, while the still
                // underneath rendered fine because `ImageStore` sniffs the bytes
                // rather than the name. Everything on this tab is a GIF; one
                // that turns out to be a single frame is recorded in
                // `isKnownStill` and never asked again.
                if !gif.isVideo, gif.videoURL == nil, let url = gif.previewURL {
                    AnimatedDecoration(
                        url: url,
                        side: Self.tileSide,
                        gravity: .resizeAspectFill
                    )
                }
            }
            .clipShape(.rect(cornerRadius: Radius.chip, style: .continuous))
            .contentShape(.rect)
    }

    /// What a tile is drawn at.
    ///
    /// The decode never upscales past the source, so a small preview costs no
    /// more than its own pixels, and a large one is decoded to the tile.
    private static let tileSide: CGFloat = 160

    static func split(_ gifs: [GIF], into count: Int) -> [[GIF]] {
        var columns = [[GIF]](repeating: [], count: count)
        var heights = [CGFloat](repeating: 0, count: count)
        for gif in gifs {
            var shortest = 0
            for index in 1..<count where heights[index] < heights[shortest] { shortest = index }
            columns[shortest].append(gif)
            // Every tile is the same width, so the aspect ratio IS the relative
            // height.
            heights[shortest] += 1 / max(gif.aspectRatio, 0.2)
        }
        return columns
    }

    // MARK: Pieces

    private var searchField: some View {
        HStack(spacing: Spacing.base) {
            Image(systemName: "magnifyingglass")
                .font(.system(.body))
                .foregroundStyle(Ink.tertiary)
            TextField(store.scope?.searchPlaceholder ?? "Search GIFs", text: $query)
                .textFieldStyle(.plain)
                .font(.system(.body))
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(.body))
                        .foregroundStyle(Ink.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, Spacing.snug)
        .frame(minHeight: Metrics.control)
        .chromeOverMedia()
    }

    private func scopeHeader(_ scope: GIFScope) -> some View {
        Button {
            // Clearing the field and leaving a scope are the same gesture, so
            // both go through one state change.
            query = ""
            store.leaveScope()
        } label: {
            HStack(spacing: Spacing.tight) {
                Image(systemName: "chevron.left")
                    .font(.system(.footnote, weight: .semibold))
                Text(scope.title)
                    .font(.system(.subheadline, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Ink.primary)
            .padding(.horizontal, Spacing.snug)
            .frame(minHeight: Metrics.control)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .interactiveChromeOverMedia()
    }

    private var loading: some View {
        ProgressView()
            .controlSize(.small)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func message(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(.system(.subheadline))
                .foregroundStyle(Ink.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

/// Where the GIF tab is. Nil is the landing grid.
enum GIFScope: Hashable, Sendable {
    case favorites
    case trending
    case category(String)
    case search(String)

    var title: String {
        switch self {
        case .favorites: "Favorites"
        case .trending: "Trending GIFs"
        case .category(let name), .search(let name): name
        }
    }

    var searchPlaceholder: String {
        switch self {
        case .favorites: "Search Favorites"
        default: "Search GIFs"
        }
    }
}

/// The GIF tab's fetches, and the one rule that keeps them honest: **a result
/// that arrives after the reader has moved on is dropped.**
///
/// Every load re-checks the scope it was started for before writing. Without
/// that, a tile opened while the previous one is still in flight has the older
/// page land on top of it — which reads as the picker opening the wrong
/// category.
@Observable
@MainActor
final class GIFStore {
    private(set) var categories: [GIFCategory] = []
    private(set) var results: [GIF] = []
    private(set) var trendingSeed: [GIF] = []
    private(set) var scope: GIFScope?
    private(set) var isLoading = false

    /// The session is reached through the store, which is where every other
    /// surface's fetches go. Held weakly-by-value — this is a view's `@State`
    /// and outlives nothing.
    var session: SessionController?

    func loadLanding() async {
        guard categories.isEmpty, !isLoading, let session else { return }
        isLoading = true
        defer { isLoading = false }
        guard let landing = try? await session.gifLanding() else { return }
        categories = landing.categories
        trendingSeed = landing.trending
    }

    /// Favourites need no request: they are already in the account's settings.
    func openFavorites(_ favorites: [GIF]) {
        scope = .favorites
        results = favorites
    }

    func openTrending() async {
        scope = .trending
        // The seed shows immediately so the list is never blank while the full
        // page is in flight.
        results = trendingSeed
        isLoading = true
        defer { isLoading = false }
        let page = (try? await session?.trendingGIFs()) ?? []
        guard scope == .trending, !page.isEmpty else { return }
        results = page
    }

    func open(category name: String) async {
        scope = .category(name)
        results = []
        isLoading = true
        defer { isLoading = false }
        let page = (try? await session?.searchGIFs(name)) ?? []
        guard scope == .category(name) else { return }
        results = page
    }

    func search(_ query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        scope = .search(trimmed)
        isLoading = true
        defer { isLoading = false }
        let page = (try? await session?.searchGIFs(trimmed)) ?? []
        guard scope == .search(trimmed) else { return }
        results = page
    }

    /// An emptied field leaves a *search* scope and nothing else. A debounced
    /// empty query arriving just after a tile was opened must not throw the
    /// reader back to the landing grid.
    func searchCleared() {
        if case .search = scope { leaveScope() }
    }

    /// Back to the landing. No request: the categories are already here.
    func leaveScope() {
        scope = nil
        results = []
    }
}
