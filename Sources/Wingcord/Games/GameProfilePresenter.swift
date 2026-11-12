import SwiftUI
import WingcordCore

/// The one place a game's profile is presented.
///
/// **A layer in the window, not a `.sheet`** — the same correction the profile
/// card already made, and for one of the same two reasons: a presentation is an
/// `NSWindow` that paints its own backdrop material behind everything in it, and
/// `.presentationBackground(.clear)` does not suppress it. This page is a rounded
/// card with a shadow; inside a sheet it would be a rounded card inside a grey
/// square.
///
/// It is also raised **from inside** other layers — a board tile's menu, a cover
/// on somebody's profile — and a sheet presented from a view that is itself
/// being torn down is a race. Writing a request to the store and reading it here
/// has no such window.
struct GameProfilePresenter: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.motion) private var motion

    /// The page's ideal size, clamped to the window in the body below.
    ///
    /// Wide enough for a 16:9 stage beside the 320-point aside with the three
    /// floating objects' own margins, and no taller than the shortest window
    /// this app allows. The spec's numbers.
    private static let idealWidth: CGFloat = 1_100
    private static let idealHeight: CGFloat = 780
    /// How much of the window is left around it.
    private static let inset: CGFloat = 48

    func body(content: Content) -> some View {
        content.overlay {
            GeometryReader { proxy in
                ZStack {
                    if let request = model.gameProfileRequest {
                        // The scrim, and the way out. A `Button` rather than a
                        // tap gesture: it is what `.keyboardShortcut` attaches
                        // to, VoiceOver can find it, and the two ways out of
                        // this page become one object instead of two that can
                        // disagree.
                        Button { model.dismissGameProfile() } label: {
                            Color.black.opacity(0.5).contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .cancelAction(unless: model.isCovered(.gameProfile))
                        .accessibilityLabel(Text("Close game profile"))
                        .transition(.opacity)

                        page(request, container: proxy.size)
                    }
                }
                // Declared by the container rather than by the writer: a
                // `withAnimation` around a store write opens a global
                // transaction and animates every view that happens to re-lay-out
                // while it runs.
                .animation(motion.panel, value: model.gameProfileRequest)
            }
        }
    }

    @ViewBuilder
    private func page(_ request: GameProfileRequest, container: CGSize) -> some View {
        let width = min(Self.idealWidth, max(container.width - Self.inset * 2, 320))
        let height = min(Self.idealHeight, max(container.height - Self.inset * 2, 240))

        Group {
            if let game = model.gamePresentation(for: request.gameID) {
                GameProfileView(game: game) { model.dismissGameProfile() }
                    .equatable()
            } else {
                // The game itself has not landed. Everything else on this page
                // is optional and fills in around it, but the page cannot be
                // headed by a snowflake — so this is the one place the sheet
                // waits.
                GameProfileLoading { model.dismissGameProfile() }
            }
        }
        .frame(width: width, height: height)
        // **Scale and opacity, no blur** — Motion's own rule for a surface
        // whose ground is a material. The blur put the whole page, three
        // materials and a playing trailer through an off-screen pass on every
        // frame of its arrival, which is the moment the page is also decoding
        // its pictures.
        .transition(.materialize(from: .center, blurring: false))
    }
}

/// The page before its game has arrived.
///
/// The same box at the same size, so the page does not resize under the reader
/// the moment `/games` answers.
private struct GameProfileLoading: View {
    var dismiss: () -> Void

    var body: some View {
        VStack(spacing: Spacing.snug) {
            ProgressView().controlSize(.small)
            Text("Loading the game…")
                .font(Typeface.rowSubtitle)
                .foregroundStyle(InkColor.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.surface)
        .clipShape(.rect(cornerRadius: Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Ink.quaternary, lineWidth: 1)
        }
        .overlay(alignment: .topTrailing) {
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(Typeface.controlGlyph)
                    .foregroundStyle(InkColor.secondary)
                    .frame(width: Metrics.control, height: Metrics.control)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .interactiveChrome(in: .circle)
            .padding(Spacing.snug)
            .accessibilityLabel(Text("Close"))
        }
        .shadow(color: .black.opacity(0.5), radius: 36, y: 14)
    }
}

extension View {
    /// Apply once, at the window root.
    func presentsGameProfile() -> some View {
        modifier(GameProfilePresenter())
    }
}
